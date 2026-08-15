# MBIM contract v1 (0.12.0)

Status: accepted design for 0.12.0, implemented and covered by fixtures. The
adapter, the APN backend, the attempt planner, readiness, roaming policy,
provisioning and the LuCI control all exist; **nothing here has run on
hardware**, so MBIM ships as `alpha`/`synthetic` until the gate in
[`testing-0.12.0.md`](testing-0.12.0.md) is recorded. This document is normative
for the native MBIM backend and for the MBIM parts of `apn-autoconfig-modem`. It extends [`backend-contract-v1.md`](backend-contract-v1.md)
and [`provisioning-contract-v1.md`](provisioning-contract-v1.md) and inherits
every rule in them, including the lock representation, the lock ordering and the
ownership markers. The safety invariants in [`architecture.md`](architecture.md)
remain binding.

MBIM is the third native transport after ModemManager and QMI. The release goal
is one complete vertical slice — discovery, provisioning, identity, profile
write, verification, roaming policy and exact rollback — not an isolated
parser.

## Runtime this contract targets

Verified on the reference router (OpenWrt 25.12.5 r33051-f5dae5ece4) and against
the exact `umbim` revision it ships, `umbim 2025.10.04~2939b7d0` — upstream
`openwrt/umbim` commit `2939b7d0`. `libmbim` and `kmod-usb-net-cdc-mbim` are
present; `mbimcli` is **not** installed and must not become a dependency.

`umbim` is the only MBIM control command this project uses, and only its
read-only subset. Facts that shape the whole contract:

1. **Exit status carries state, not just failure.** `registration` exits `0`
   only for `home`, and otherwise returns the numeric register state; likewise
   `subscriber` exits `0` only for `initialized`. A short or malformed message
   exits `-1` (255). Validated stdout is therefore authoritative, and exit status
   alone can never classify a response.
2. **`-t <id>` suppresses the MBIM OPEN message and `-n` suppresses the CLOSE.**
   Every combination is meaningful, and the wrong one either fails or tears down
   a live bearer.
3. `umbim` bounds a single message at 15 s internally. That is not proof that
   the process cannot hang, so every invocation still gets an outer bound.
4. `/lib/netifd/proto/mbim.sh` keeps **one control session open for the life of
   the bearer**. It starts at transaction id 2, increments per message, and
   stores the next id with `uci_set_state network <interface> tid`. Teardown
   issues `umbim -t <tid> … disconnect` without `-n`, which closes the session,
   and reverts the state variable.
5. MBIM transaction ids need only be unique among *outstanding* transactions.

## Ownership boundary

| Concern | Owner |
|---|---|
| bearer lifecycle, dynamic interfaces, DNS/routes | netifd (`mbim.sh`) |
| section existence, `proto`, `device`, `disabled`, `auto` | `apn-autoconfig-modem` |
| `apn`, `username`, `password`, `auth`, `pdptype` | `apn-autoconfig` |
| `allow_roaming`, `allow_partner` | `apn-autoconfig` roaming policy |
| everything else in the section | nobody in this project |

`mbim.sh` also accepts `ipv6`, `dhcp`, `dhcpv6`, `pincode`, `delay`, `mtu`,
`devpath`, `sourcefilter` and `delegate`. Those are transport and connection
options, not APN profile fields; this project reads some of them as external
constraints and never writes them.

The MBIM adapter is used only for a modem under **netifd-direct** control. A
modem owned by ModemManager keeps the ModemManager path even when its kernel
transport is CDC-MBIM, exactly as a ModemManager-owned QMI modem does today.

## The identity adapter

`/usr/libexec/apn-autoconfig-mbim` ships in the existing `apn-autoconfig`
package next to `apn-autoconfig-qmi`, and has the same two operations:

```text
apn-autoconfig-mbim capabilities
apn-autoconfig-mbim identity /dev/<safe-mbim-control-device>
```

It is strictly read-only. It issues only:

```text
umbim … subscriber
umbim … home
umbim … registration
```

It never issues `connect`, `disconnect`, `attach`, `detach`, `unlock`, `config`
or `radio`, never writes UCI, never changes SIM or radio state and never starts
or stops a bearer. Connection ownership remains in netifd.

### Device resolution

Only `/dev/cdc-wdm<N>` and `/dev/wwan<N>mbim<M>` names are accepted, with numeric
suffixes and no path separators, mirroring `apn-autoconfig-qmi`. The core passes
either the selected target's explicit `device` or exactly one control channel
resolved below a validated OpenWrt `devpath` in sysfs. Zero or multiple matches
fail closed rather than selecting by enumeration order, and a symlink leaving
the configured sysfs root fails closed.

### Session coexistence

The adapter must never close a session it did not open, and must never send a
command into a device where no session is open. It resolves the netifd section
bound to the selected device and decides from that section's runtime state:

| Observed state | Action |
|---|---|
| no `tid` state and the interface is down | open a private session: no `-t`, no `-n`, so `umbim` closes it again |
| `tid` state present and the interface is up | `umbim -n -t <own id> …`: no OPEN, no CLOSE |
| no `tid` state while the interface is up, or the interface is pending | exit 3 retryable; a transition is in flight |
| `tid` present while the interface is down | stale record: open a private session and log it |

The last row matters for recovery. `mbim.sh` reverts the id during teardown, so
an id left behind on a down interface belongs to a session nothing is using —
one killed teardown would otherwise make identity permanently retryable, and a
private OPEN both works and clears the orphan.

Own transaction ids come from a fixed high range that cannot collide with
netifd's small ascending counter, and increment per message within one adapter
run. This is safe only because the adapter holds the per-device identity lock —
the same lock namespace `apn-autoconfig-qmi` uses, so an MBIM read cannot race a
QMI identity transaction on the same hardware — and because it refuses to run
while netifd is mid-transition.

### Identity mapping

Successful output is the v1 identity TSV defined in
[`backend-contract-v1.md`](backend-contract-v1.md). Sources:

| Field | Source | Rule |
|---|---|---|
| `iccid` | `subscriber` → `simiccid` | required; digits only; otherwise fail closed |
| `imsi` | `subscriber` → `subscriberid` | empty when `dont display subscriberID: 1` is present |
| `operator_id` | `home` → `provider_id` | the genuine home PLMN |
| `operator_name` | `home` → `provider_name` | |
| `serving_operator_id` | `registration` → `provider_id` | |
| `serving_operator_name` | `registration` → `provider_name` | |
| `registration_state` | `registration` → `registerstate` | mapped below |
| `roaming` | derived from `registerstate` | `true` for roaming and partner |
| `modem_state` | derived | `connected` when the section is up, else `enabled` |
| `eid`, `gid1`, `gid2` | — | always empty; MBIM has no read-only source here |
| `access_technologies` | — | always empty; see below |
| `signal_quality` | `home` → `rssi` | see below |

Register states are read from the numeric field, not the label:

| MBIM | Normalized |
|---|---|
| `3` home | `home` |
| `4` roaming | `roaming` |
| `5` partner | `roaming` |
| `6` denied | `denied` |
| `2` searching | `searching` |
| `1` deregistered | `idle` |
| `0` unknown | `unknown` |

`partner` is a preferred-roaming-partner registration, not a home registration.
It maps to the normalized roaming state, and OpenWrt gates it with its own
`allow_partner` option — see the roaming policy below.

Subscriber ready states other than `initialized` are not identity failures to be
guessed at: `sim-not-inserted`, `bad-sim`, `not-activated`, `device-locked`,
`failure` and `not-initialized` each exit 3 with a distinct log line. This
release does not unlock a PIN.

Unlike `uqmi`, MBIM reports a real home provider, so the candidate matcher uses
`operator_id` directly instead of falling back to the IMSI MCC/MNC prefix. A
roaming serving PLMN is still never presented as the SIM's home operator.

### Access technology and signal

`access_technologies` stays empty. The only read-only source is
`availabledataclasses`, which is a bitmask of what the network *offers*, and
`currentcellularclass`, which distinguishes GSM from CDMA rather than naming a
radio access technology. Reporting either as the current RAT would be a guess,
and the project's rule is that unknown values stay empty.

`signal_quality` is parsed from the home provider's `rssi` field only when it is
in the MBIM range `1`–`31`, mapped as `-113 + 2·rssi` dBm and then to percent
with the existing clamp. `0` and `99` mean "unknown" often enough on real
firmware that they are treated as unknown, not as -113 dBm. Whether this field
tracks real signal on the reference modem is a question for the hardware gate;
until it is answered the empty result is the correct one, and an empty signal
never makes otherwise valid identity unavailable.

### Exit codes

Same classes as the QMI adapter: `0` complete valid identity, `1` malformed
input or response, `2` invalid invocation, `3` dependency or device temporarily
unavailable, a bounded command failed, or a netifd transition is in flight. The
core maps `3` to its retryable exit class.

## Profile write, auth and IP family

The backend owns exactly `apn`, `username`, `password`, `auth` and `pdptype`,
captured into the existing baseline before the first write and restored exactly
on any failure.

`pdptype` for MBIM is `ipv4`, `ipv6` or `ipv4v6` — **not** QMI's `ip`. Any other
value means "let the modem decide", so the backend writes only the three known
values.

`umbim connect` accepts exactly one authentication protocol — `pap`, `chap` or
`mschapv2` — and, critically, **discards the username and password entirely**
when the value is not one of those three. A normalized `pap-or-chap` candidate
must therefore never be written verbatim. It expands into bounded attempts,
`chap` first and then `pap`, and the effective value that worked is what the
cache and the reconciled state record. A provider-label refresh still treats
either effective value as matching a database `pap-or-chap` profile.

A requested `ipv4v6` bearer that does not become ready gets one explicit IPv4
retry, and IPv4 becomes the effective cached profile when it succeeds — the same
single bounded downgrade QMI has, expressed in a shared per-backend attempt
planner rather than a second hard-coded special case. No other IP family is
silently changed.

A pre-existing `ipv6=0` is an external constraint set by whoever configured the
interface. The backend respects it instead of rewriting it: an IPv6-only
candidate is incompatible, and a dual-stack candidate reduces to an explicit
IPv4 attempt.

## Readiness

`mbim.sh` publishes dynamic `${interface}_4` and `${interface}_6` interfaces via
`ubus network add_dynamic`, choosing them from the connect response's IP type.
The parent section carries no address of its own. Connectivity verification
therefore waits for an addressed `${interface}_4` and/or `${interface}_6`
matching the effective family before it declares the bearer usable — the same
readiness rule QMI already needs, generalized rather than duplicated.

## Roaming policy

OpenWrt's MBIM handler has two boolean options where ModemManager has one, and
its default is the opposite of ModemManager's:

| Requested | `allow_roaming` | `allow_partner` |
|---|---|---|
| `allow` | `1` | `1` |
| `block` | `0` | `0` |
| `default` | deleted | deleted |

| Observed | Reported policy |
|---|---|
| both `1` | `explicit-allow` |
| both `0` | `explicit-block` |
| both absent | `default-block` |
| any other combination | `invalid` |

A mixed pair is surfaced as invalid and never guessed at or silently
normalized: someone configured it deliberately, and this project does not own
the answer. Because absent means *blocked* on MBIM and *allowed* on
ModemManager, LuCI labels and help text for this control are backend-specific.

Applying `block` while the modem is registered in roaming brings the interface
down, exactly as the ModemManager path does today.

## Inventory and provisioning

Inventory continues to classify an MBIM modem from its `cdc_mbim` driver binding
and does **not** open an MBIM control channel. Identity for inventory purposes
stays with USB topology and serial or IMEI evidence; there is no direct `umbim`
probe from the inventory scan in this release. That keeps discovery read-only in
the strongest sense and avoids a second, differently-locked control path into the
same hardware.

Provisioning gains `mbim` as an implemented protocol. The staging section is
created exactly as for QMI — `proto=mbim`, the resolved control device, the three
ownership markers, `disabled=1`, `auto=0` and **no** `apn` option — so netifd
cannot dial a vendor default before reconciliation chooses a profile. Every rule
in [`provisioning-contract-v1.md`](provisioning-contract-v1.md) applies
unchanged, including no adoption of user-created sections and exact rollback of
anything provisioning created.

`connect`, `disconnect` and `reconnect` are already protocol-neutral: they act on
a project-owned section through netifd and gain no MBIM-specific behavior.

## Capability, implementation and validation state

These stay three separate fields. MBIM ships as `implementation_state: alpha`
and `validation_state: synthetic` and becomes `stable` / `hardware` with
`hardware_validated: true` only after the live gate in
`docs/testing-0.12.0.md` passes on the reference hardware. A passing fixture
suite is necessary and never sufficient. `roaming_policy_read` and
`roaming_policy_write` are reported as separate booleans, additively, so a
consumer never infers policy support from a backend name.

A missing `umbim` makes the MBIM capabilities false without hiding the
configured cellular target, exactly as a missing `uqmi` or `mmcli` does.
