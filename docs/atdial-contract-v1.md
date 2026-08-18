# AT-dial contract v1 (0.15.0)

Status: accepted design for 0.15.0. The `apn_atdial` netifd protocol, its
bounded AT executor, the provisioning path and the APN backend are implemented.
Hardware evidence is recorded in [`testing-0.15.0.md`](testing-0.15.0.md) and
covers the Fibocom FM350-GL only; the Intel XMM tail described below ships
`alpha`/`synthetic` and no part of this document may be read as a hardware claim
for it.

This document is normative for the `apn-autoconfig-proto-atdial` package and for
the AT-dial parts of `apn-autoconfig-modem` and `apn-autoconfig`. It extends
[`backend-contract-v1.md`](backend-contract-v1.md),
[`modem-contract-v1.md`](modem-contract-v1.md) and
[`provisioning-contract-v1.md`](provisioning-contract-v1.md) and inherits every
rule in them, including the AT port lock, the lock ordering and the ownership
markers. The safety invariants in [`architecture.md`](architecture.md) remain
binding.

## What this protocol is for

The three transports that came before all dial through a control channel the
kernel exposes as a character device: `cdc-wdm` for QMI and MBIM, and a
ModemManager object standing on top of one of them. A modem in an RNDIS, ECM or
NCM composition has **no such node at all**. Its data path is an ordinary usbnet
interface, and the host is responsible for everything the control channel would
otherwise have done: define the PDP context, activate it, ask the modem which
address it was given, and put that address on the interface itself. The modem
serves no DHCP, so nothing else will do it.

That is the whole protocol. The commands are plain 3GPP — `AT+CGDCONT`,
`AT+CGACT`, `AT+CGPADDR`, `AT+CGCONTRDP` — and they are the same on every vendor
that implements the specification. What differs between devices, and what this
contract spends most of its length on, is everything around them: which node
accepts the commands, who is allowed to talk to it, what has to be true before
dialing is even meaningful, and how a device that diverges from the
specification is accommodated without guessing on behalf of devices nobody has
tested.

## Runtime this contract targets

The reference router runs OpenWrt 25.12.5 r33051-f5dae5ece4, kernel 6.12.94.
Four properties of it shape the implementation:

1. **There is no `timeout` executable.** BusyBox here does not provide one. The
   watchdog fallback in the bounded executor is therefore not a defensive branch
   for exotic images — it is the only branch that has ever run on this hardware,
   including for the AT fallback that is already marked hardware-validated. It
   is tested as the normal path, not as the exception.
2. **`sms_tool` is the AT transport**, as it already is for
   `apn-autoconfig-modem` and the QMI adapter's identity fallback. No new
   transport is introduced, and no new dependency beyond the kernel modules
   below.
3. **The measured FM350-GL binds no driver on arrival.** Its interface classes
   are `02/02/ff` plus `0a/00/00` — the RNDIS signature — and on this image
   `rndis_host` is not loaded while `cdc_ether`, `cdc_ncm`, `cdc_mbim` and
   `qmi_wwan` are. The modem therefore has no network device whatsoever until
   something loads the driver. The protocol handler must do it.
4. **Five of that modem's seven tty nodes accept a write and never answer.**
   Port resolution is expensive and is already solved once, in
   `apn-autoconfig-modem`; this protocol asks it rather than repeating it.

## Naming, and why it is not `fibocom`

The protocol is `apn_atdial` and its handler is
`/lib/netifd/proto/apn_atdial.sh`.

`fibocom` was the obvious name and is not available. `luci-app-5gmodem` already
installs `/lib/netifd/proto/fibocom.sh`, so claiming that path would make the
two projects mutually uninstallable — a cost paid by users, for a name. It is
also the wrong name: the same 3GPP dial drives MediaTek, Intel XMM and other
AT-managed devices, so a vendor in the protocol name would be inaccurate as soon
as the second device is supported.

The name is a valid shell identifier by necessity, not by preference. netifd
composes handler function names as `proto_<name>_setup`, so the protocol name
becomes part of a shell function name; `dash` rejects
`proto_apn-atdial_init_config() { … }` with `Bad function name`. A hyphen would
not be a style question but a handler that fails to define itself. Underscores
are valid, and `3g` proves a leading digit is too.

The APN engine continues to recognise foreign `fibocom`, `atc`, `xmm`, `ncm`,
`wwan` and `3g` sections as cellular targets it does not implement. Not wanting
the name is not the same as not interoperating with it.

One consequence of how netifd loads handlers reaches this contract directly.
netifd spawns the handler from disk for every setup and teardown, so changed
dial logic takes effect at the next bring-up — but it reads the registration and
the **option schema** only when it starts, from the handler's `dump` output. An
interface option added to this handler is therefore not accepted from the config
until netifd restarts, which for most users means their next reboot. Any option
added after this release must default to behaving exactly as its absence does
today.

## Ownership boundary

| Concern | Owner |
|---|---|
| bearer lifecycle, addresses, routes, DNS, dynamic interfaces | netifd (`apn_atdial.sh`) |
| section existence, `proto`, `usbpath`, `modem_id`, `disabled`, `auto` | `apn-autoconfig-modem` |
| `apn`, `username`, `password`, `auth`, `pdptype` | `apn-autoconfig` |
| `allow_roaming` | `apn-autoconfig` roaming policy |
| AT port resolution, identity, control-owner arbitration, reset | `apn-autoconfig-modem` |
| everything else in the section | nobody in this project |

The handler also accepts `device`, `atport` and `metric`. `metric` is a routing
preference, and `device`/`atport` are escape hatches for a hand-written section;
this project writes none of the three and never rewrites them.

## Interface options

```text
usbpath   stable USB topology path of the modem, e.g. 2-1.3 (preferred binding)
modem_id  stable modem identity, as issued by apn-autoconfig-modem
device    usbnet device; used only when usbpath resolves nothing
atport    AT control port; used only when the modem package cannot resolve one
apn       access point name
username  PDP authentication user
password  PDP authentication secret
auth      none | pap | chap | pap-or-chap
pdptype   IP | IPV6 | IPV4V6
metric    route metric
allow_roaming  0 | 1
```

`usbpath` and `modem_id` are written by `apn-autoconfig-modem` at provisioning
and are the binding. `usbpath` alone is not identity — it is where the modem was
— so a section whose `usbpath` no longer holds a USB device is re-resolved from
`modem_id` through the modem package rather than trusted or guessed.

## Setup sequence

Every step below is bounded, and every failure maps to exactly one error class.

### 1. Resolve the network device, loading its driver first

Collect the network devices belonging to this exact USB device, and take the one
whose **USB interface number is numerically lowest**. Glob order is not interface
order: ASCII sorts `1.10` before `1.6`, and a device exposing three NCM
interfaces hands out the wrong one to a lexical comparison. On an Intel XMM
device this is not cosmetic — the data-channel binding in the XMM tail names the
first NCM interface explicitly, so picking a different one produces a link that
is up and carries nothing.

If no network device exists, load `rndis_host`, `cdc_ether` and `cdc_ncm`
(`modprobe` is idempotent; a loaded module is a no-op) and wait, bounded, for the
kernel to attach one — loading a usbnet module makes it scan devices that are
already present. If none appears within the bound, the class is `NO_NETDEV`.

A `device` taken from the section is not evidence that it exists. If the
resolved name has no entry under `/sys/class/net`, the class is `NETDEV_MISSING`
and restarts are blocked: netifd would otherwise re-enter setup every few
seconds forever, and an honest permanent error is better than an infinite loop
that explains nothing.

### 2. Resolve the AT control port through the modem package

The handler does not probe ports. It asks
`apn-autoconfig-modem at-port --modem <modem_id>`, which resolves by observed
role, uses the lazy positive-and-negative cache, and refuses when the modem is
owned by ModemManager. This is deliberate and load-bearing: a second
implementation of port resolution in a second package, racing the first one for
the same tty, is precisely the failure 0.14.0 exists to prevent.

A refusal for ownership is `OWNER_CONFLICT`. No resolvable port is `NO_AT_PORT`.
An explicit `atport` in the section is honoured as-is for a hand-written
section, and is still subject to the lock below.

### 3. Take the AT port lock, and only then dial

The lock is the shared `/var/lock/apn-autoconfig-at-port.<tty>` namespace that
`apn-autoconfig-modem` and `apn-autoconfig-qmi` already contend on, with the
same live-PID reclaim.

**It is mandatory.** Failing to acquire it within the bound is `AT_PORT_BUSY`
and the setup refuses. Waiting and then proceeding unlocked is not an available
behaviour, and the damage it causes is concrete rather than theoretical: a tty
is effectively exclusive, so a second reader takes replies that belong to the
first. The address published on the interface is read from a reply to
`AT+CGPADDR`, and an interface configured with another component's answer is
up, wrong, and silent about it.

After the lock is held, the modem's presence, identity and control owner are
re-read before the first command. Validation performed before the lock has a
time-of-check/time-of-use gap, and this modem class demonstrably closes that gap
the wrong way: ModemManager on the reference router claimed the FM350 roughly an
hour after it was attached, so a scan that ran early saw no owner and a later one
saw ModemManager.

The lock is released as soon as the last AT command has been issued — before
addresses, routes and the IPv6 child are published — so the port returns to
identity and status readers as early as possible.

### 4. Establish that there is a network before dialing

Read registration once, preferring `+CEREG`, then `+CGREG`, then `+CREG`, and
decide roaming, permanent refusal and "no network yet" from that single read.

| `stat` | Meaning | Action |
|---|---|---|
| 1, 6, 9 | registered, home (6 and 9 are SMS-only and CSFB variants) | dial |
| 5, 7, 10 | registered, roaming | dial only when `allow_roaming` is 1 |
| 3 | registration denied | `REGISTRATION_DENIED`, block restart |
| 0, 2, 4, 8 or no reply | no network yet | wait, then `NOT_REGISTERED` |

Codes 6 and 7 are not padding. `+CREG: 0,6` — registered for SMS only, home —
is what the reference FM350 actually returns while attached over LTE with no CS
domain, and a mapping covering only 0/1/2/3/5 would misread it as "no network".
That the preferred sources both answered 1 in the same moment is also the
evidence for the preference order.

A modem that has been deregistered does not recover on its own. When `+COPS?`
reports **mode 2**, automatic operator selection is re-enabled once per attempt
with `AT+COPS=0`. The trigger is the mode, not a `stat` code, because the `stat`
a deregistered modem reports varies by device while mode 2 is unambiguous. Mode
1 is left alone: a manual operator choice is the user's, and overriding it is
not this handler's business.

Registration is polled up to its bound before giving up, because a modem that
has just powered on honestly takes tens of seconds to find a network. That wait
doubles as the interval between netifd retries, so no separate throttle exists.

`ROAMING_NOT_ALLOWED` and `REGISTRATION_DENIED` block restarts; `NOT_REGISTERED`
never does, because signal returning is exactly the case where the interface
must come up without a human.

### 5. Dial

```text
AT+CGDCONT=1,"<pdptype>","<apn>"
AT+CGAUTH=1,<0|1|2>[,"<user>","<password>"]
AT+CGACT=0,1
AT+CGACT=1,1        (retried, bounded)
AT+CGPADDR=1        until a non-zero address appears
AT+CGCONTRDP=1      gateway and DNS
```

Four rules attach to that sequence.

**`pdptype` is normalised to 3GPP values.** `AT+CGDCONT` accepts `IP`, `IPV6`
and `IPV4V6` and nothing else. `IPV4` is not a valid value, and a device that
answers `ERROR` to it leaves the previous context in place — which means the
previous SIM's APN survives, every dial silently uses it, and the interface
appears to work while pointing at the wrong network. The engine writes canonical
values; this normalisation exists to absorb hand-written ones.

**The context is released before it is activated.** A bare re-activation hangs
when the context is wedged half-active, and `AT+CGACT=0,1` clears that state. On
a cold context the release is a harmless no-op, so it is unconditional rather
than conditional on detecting a state that cannot be detected reliably.

**Authentication is written on every cold dial, and credentials never reach a
log.** `auth=none` writes `AT+CGAUTH=1,0` so a previous SIM's credentials cannot
persist into a profile that has none. `pap-or-chap` expands into bounded CHAP
then PAP attempts and the effective value is cached, exactly as the MBIM backend
already does for the same reason: the modem accepts one protocol per context,
and which one worked is a fact worth keeping rather than rediscovering. A modem
without `AT+CGAUTH` answers `ERROR`, and a profile with no credentials is
unaffected.

**A PDP-type fallback fires only after failure.** When the configured type
yields no address, the complementary type is tried once. Some SIMs bring up the
default bearer only under one of them. Because it is reached only on failure,
the common case pays nothing for it, and the live context's actual type — not
the configured one — decides whether IPv6 is brought up.

### 6. Reusing a context that is already active

A modem that has just booted may have activated context 1 by itself, with the
APN it last held. Reuse is permitted only when **all** of the following are
true, and each condition exists because its absence produced a real failure:

- the configured APN matches the live one, or no APN is configured — otherwise a
  new SIM's APN never takes effect and the old operator's context is used
  forever;
- the PDP type matches — otherwise `IPV4V6` requested over a live `IP` context
  reuses an IPv4-only bearer and IPv6 never appears, because no modem upgrades a
  context in place;
- `AT+CGATT?` reports 1 — an active context with a stale address on a detached
  modem is a dead bearer, and publishing it produces an interface that is up and
  carries nothing. This mirrors what `qmi.sh` does with its data-status check
  before declaring success;
- authentication is configured but the modem has not re-enumerated since it was
  sent — `AT+CGAUTH` does not survive a modem reboot while `AT+CGDCONT` does, so
  the context can match perfectly while the bearer is unauthenticated. That is
  again an address with no traffic. Re-enumeration is detected from the USB
  `devnum`, which changes on every enumeration.

Reuse is an optimisation for the case where netifd re-enters setup without the
modem having changed. It is never a substitute for a cold dial.

### 7. Publish

IPv4 is static, from `AT+CGPADDR`: address, and a default route through the
`AT+CGCONTRDP` gateway or on-link when that field is empty, which on
point-to-point cellular links it usually is. DNS servers come from the same
reply.

IPv6 is **not** taken from `AT+CGPADDR`. On a cellular link the routable prefix
arrives by router advertisement or DHCPv6 on the usbnet interface, with the
modem acting as a router; `CGPADDR` carries only an interface identifier. A
dynamic `dhcpv6` child interface is created instead, inheriting the parent's
firewall zone so that inbound RA and DHCPv6 replies are not dropped by the input
policy. It is created only when the **live** context is v6-capable.

## Teardown

Teardown deactivates the PDP context.

This is a deliberate divergence from the reference implementation studied for
this release, which leaves the bearer up so that a route-metric change
reconnects instantly and losslessly. That is a real benefit and this project
cannot take it. netifd is the sole bearer owner here; a data session that
outlives the interface that owns it is exactly the state invariant 5 forbids,
and it is invisible — nothing in the system reports a bearer that no interface
claims. The cost is a slower reconnect after any reconfiguration, and it is
recorded here so a later reader can weigh it rather than rediscover it.

Teardown sends no `proto_send_update`. netifd has already entered `S_TEARDOWN`
by the time the handler runs, and `proto_ext_update_link` answers
`UBUS_STATUS_PERMISSION_DENIED` in that state, so the notification cannot
succeed and only produces a permission-denied line in the log on every
disconnect. Error codes travel by a different path and still arrive.

## Error classes

| Class | Meaning | Blocks restart |
|---|---|---|
| `NO_NETDEV` | no network device, and none appeared after loading the usbnet drivers | no |
| `NETDEV_MISSING` | a configured device name does not exist in the system | yes |
| `NO_AT_PORT` | no AT control port could be resolved for this modem | no |
| `AT_PORT_BUSY` | the shared AT port lock was not acquired within its bound | no |
| `OWNER_CONFLICT` | ModemManager owns this modem, or ownership is uncertain | yes |
| `ROAMING_NOT_ALLOWED` | roaming registration while `allow_roaming` is 0 | yes |
| `REGISTRATION_DENIED` | the network refused registration (`stat` 3) | yes |
| `NOT_REGISTERED` | no registration within the bound | no |
| `NO_IP_ADDRESS` | the context did not activate, under either PDP type | yes |

Restarts are blocked only where repetition cannot help. A blocked restart that
is later resolved by the user — enabling roaming, fixing a SIM — is cleared by
the explicit interface start that follows.

## Quirks, and the Intel XMM tail

Divergence from the specification is carried by the quirk table in
`apn-autoconfig-modem`, keyed by the manufacturer and model the modem reports to
`AT+CGMI` and `AT+CGMM`. Its rule is unchanged and absolute: an absent entry
means "not tested here", never "probably like the others".

| Key | Values | Effect |
|---|---|---|
| `data_channel` | `xmm` | bind the first NCM channel to the context and start data after the address appears |
| `dns_source` | `xdns` | read DNS from the vendor query instead of `AT+CGCONTRDP` |
| `link_arp` | `off` | disable ARP on the link and route on-link with no gateway |

The Intel XMM devices — Fibocom L850 and L860 — need all three. Their dial is
ordinary 3GPP, but the data channel must be bound explicitly before frames move,
`AT+CGCONTRDP` returns nothing so DNS comes from `AT+XDNS?` (which must be
enabled before activation, or it answers empty), and the NCM link does not
answer ARP, so without disabling it the address is configured and every packet
dies in neighbour resolution.

**Keying on the reported model rather than the USB id is the correct choice
here, and the reason is specific.** The reference implementation detects XMM
from `idVendor == 8087`, and its own notes record that L850 and L860-GL-16 both
enumerate as `8087:095a`. The USB id cannot distinguish the two devices;
`AT+CGMM` can. Since the quirk table is read after identity is known, it costs
nothing to key on the more precise signal.

Every XMM entry is marked in the table as sourced from a third-party hardware
report rather than from this project's own bench, because that is what it is.

## Capability, implementation and validation state

These three remain separate fields and must not be collapsed.

| Path | Capability | Implementation | Validation |
|---|---|---|---|
| RNDIS/ECM dial (FM350-GL) | `identity`, `profile_apply`, `roaming_policy_read`, `roaming_policy_write` | `stable` | `hardware` |
| Intel XMM tail (L850/L860) | same | `alpha` | `synthetic` |

`profile_read` and `profile_write` are **false** for this backend, permanently
and by construction. The APN profile is a set of netifd options applied by the
protocol handler; the backend owns no profile fields of its own to read or
write. `AT+CGDCONT?` is read to decide context reuse and for diagnostic display,
which is not the same thing and must never be reported as `profile_read`.

Roaming policy is a single `allow_roaming` option enforced by the handler, not
the `allow_roaming`/`allow_partner` pair the MBIM path uses. LuCI labels are
therefore backend-specific, as they already are for MBIM.

The XMM row will move to `hardware` when an L850 or L860 has actually been
driven — not when a fixture passes. Fixtures cannot reproduce a link that
carries nothing because ARP was left on.

## What this backend never does

- It accepts **no free-form AT command** from UCI, the environment, the GUI or
  any other caller. Every string sent is a literal in the handler.
- It **never writes an APN profile into the modem** as owned state. It writes
  the context needed for this dial and nothing persistent it claims to own.
- It **never logs credentials or SIM identifiers.**
- It **never proceeds without the AT port lock**, and never treats a failed or
  unparseable ownership check as permission.
- It **never switches USB composition.** An L850 or L860 may need
  `AT+GTUSBMODE` and a modem reboot to reach the NCM composition at all; that is
  destructive, vendor-specific, and out of scope until it can be verified on
  hardware.
