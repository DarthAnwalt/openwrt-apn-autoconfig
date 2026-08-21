# Backend contract v1

This is the APN-backend contract. Its v1 meanings were released in 0.9.2 and
have not changed since; later releases added backends that conform to it —
native MBIM in 0.12.0, native AT identity in 0.14.0, the AT-dial backend in
0.15.0 — rather than altering it. The
accepted target architecture adds a lower-level modem-control boundary without
weakening this profile safety contract; see
[`architecture.md`](architecture.md). Any compatibility mapping or successor API
must be documented explicitly rather than silently changing the v1 meanings
below.

This document defines the boundary between the APN decision engine and a modem
backend. The contract is intentionally smaller than a modem-management API.
Backends identify a configured target and map a normalized mobile profile to
that target; candidate ranking, connectivity verification, caching and rollback
belong to the core.

## Capability and evidence are separate

`targets-json` v2 exposes runtime capability independently from implementation
and validation state:

- `capabilities.identity` means the installed backend can currently provide the
  identity required by `detect` and `status`;
- `profile_read`, `profile_write` and `profile_apply` describe separately
  implemented operations and must never be inferred from protocol discovery;
- `implementation_state` is `unimplemented`, `alpha` or `stable`;
- `validation_state` is `none`, `synthetic` or `hardware`;
- `hardware_validated` is false until the backend completes the documented live
  test gate;
- `roaming_policy_read` and `roaming_policy_write` describe policy support
  separately, so a consumer never infers it from a backend name. They are an
  additive extension: the existing `roaming_policy` string keeps its meaning.
  `roaming_policy_write` is also what the engine's own gate for
  `roaming-policy-set` tests. Requiring `profile_write` there refused every
  backend that owns no profile fields of its own — `atdial` among them — although
  its capability record advertised the policy correctly;
- `managed` says whether automatic operations act on this target. In automatic
  mode that is every enabled target with `profile_apply`; with an explicit
  `interface`, only that one. It is an
  additive v2 field, and a frontend must not recompute it from capabilities: a
  staged section has `profile_apply` and is deliberately not managed.

## Automatic target selection

`interface=auto` means *every* target the engine can write a profile to, not
"the only one". A router with two modems is the ordinary case, and up to 0.15.1
it was a fatal one: every command, `status` included, exited 4 with `multiple
writable cellular targets found`, so the suite stopped working at the moment it
had more to do.

- `reconcile` and `apply` run once per managed target,
  sequentially. Each run is an ordinary single-target run — it selects, locks,
  verifies and rolls back its own target — so the lock order is unchanged and
  two targets are never mutated at once.
- The aggregate exit class is the worst one that matters. A retryable result
  (3) wins, so a boot worker retries; these operations are idempotent, so the
  targets that already succeeded cost nothing on the next attempt. A hard
  failure is reported even when another target succeeded: one target must never
  be able to hide another. A target the roaming policy deliberately refused (2)
  is also the aggregate result even when another target succeeded, because an
  overall success would hide an attached modem that remains unavailable.
- `status`, `detect`, `modem-reset` and the JSON forms act on the first managed
  target: the lowest netifd route metric, section name breaking a tie. Route
  metric is the administrator's own statement of which uplink matters.
  Enumeration order decides nothing.
- `apply-manual`, `reset`, and roaming-policy changes refuse with exit 4 when
  several targets are managed and none was named. A profile the user typed, a
  rollback, and permission to spend roaming data are not operations to spread
  over targets nobody chose.
- A background APN reconciliation started without a target records the target
  `auto`, and the worker invokes the engine without `--target` so LuCI gets the
  same fan-out. Single-target actions such as modem reset and roaming policy do
  not accept `auto`.

An installed parser is not hardware support. A missing runtime command such as
`mmcli`, `uqmi` or the core dependency `sms_tool` makes the corresponding capability false without hiding the
configured cellular target.

## Native QMI adapter identity path

Stable 0.9.1 ships `/usr/libexec/apn-autoconfig-qmi`. Its public operations
are deliberately limited to:

```text
apn-autoconfig-qmi capabilities
apn-autoconfig-qmi identity /dev/<safe-qmi-control-device>
```

The adapter accepts only numeric `cdc-wdm` and `wwan…qmi…` control-device names.
The core can obtain that name from an explicit netifd `device` or resolve
exactly one matching control channel below a validated OpenWrt `devpath` in
sysfs. Zero or multiple matches fail closed instead of selecting by enumeration
order.
It first invokes only bounded, read-only `uqmi` operations:

```text
--get-iccid
--get-imsi
--get-serving-system
--get-signal-info
```

Some QMI modem firmware, including the tested RM520N, reports `Not supported`
for the native ICCID and IMSI operations while serving-system queries work. In
that case the adapter resolves `ttyUSB*`/`ttyACM*` class devices whose canonical
sysfs path belongs to the same physical USB device as the selected QMI control
channel. It probes those ports in deterministic order through `sms_tool` using
only this fixed read-only allowlist:

```text
AT+CCID
AT+QCCID
AT+CIMI
```

The standard ICCID command is tried before the Quectel-compatible variant. A
port is accepted only when it returns one valid ICCID and one valid IMSI.
Symlinks outside the configured sysfs root, ports belonging to another USB
device, non-numeric suffixes and malformed modem output fail closed. No AT
command is accepted from UCI, the environment, the GUI or another caller.

It does not verify a PIN, change SIM power, register a network, edit a QMI
profile or start/stop a bearer. Connection ownership remains in OpenWrt netifd.

Successful identity output is root-owned TSV under the following v1 contract:

```text
v1
sim_index<TAB>1
modem_index<TAB>/dev/cdc-wdm0
iccid<TAB>digits
imsi<TAB>digits
eid<TAB>
operator_id<TAB>
operator_name<TAB>
gid1<TAB>
gid2<TAB>
modem_state<TAB>connected|enabled
registration_state<TAB>home|roaming|registered|idle|searching|denied|unknown
roaming<TAB>true|false|unknown
serving_operator_id<TAB>digits-or-empty
serving_operator_name<TAB>text-or-empty
access_technologies<TAB>text-or-empty
signal_quality<TAB>0-100-or-empty
```

Unknown values are empty instead of guessed. In particular, current `uqmi`
does not expose a reliable home operator through the operations used here. The
adapter therefore leaves `operator_id` empty, and the candidate matcher uses
the IMSI MCC/MNC prefix. A roaming serving PLMN is never presented as the SIM's
home operator.

Signal information is optional. The adapter maps the best numeric RSRP from
all reported radio technologies linearly from -120 dBm (0%) to -80 dBm (100%),
clamps the result, and uses RSSI from -110 dBm to -50 dBm only when no RSRP is
available. Missing or malformed signal data leaves `signal_quality` empty and
does not make otherwise valid SIM identity unavailable. LuCI may reuse the
serving operator label for its SIM-provider and home-network rows only when
`registration_state` is explicitly `home`; it must never make that inference
while roaming.

Exit codes are:

- `0`: complete, valid identity contract;
- `1`: malformed input or response;
- `2`: invalid adapter invocation;
- `3`: dependency/device temporarily unavailable or a bounded command failed.

The core maps temporary identity failures to its retryable exit code 3.

## QMI profile write/apply

The QMI backend implements these operations as one rollback-safe unit:

1. read the complete profile fields owned by the backend;
2. validate a normalized candidate without shell evaluation;
3. persist the exact pre-change baseline atomically;
4. map the candidate to the backend's canonical netifd UCI options;
5. ask netifd to reconnect only the selected target;
6. expose the effective layer-3 device for common verification;
7. restore the exact previous profile and target state after every failure.

The core captures and restores exactly the owned QMI netifd options `apn`,
`username`, `password`, `auth` and `pdptype`. Normalized `pap-or-chap` maps to
uqmi's `both`; normalized IPv4 maps to qmi.sh's canonical `ip`. The baseline is
written atomically with mode constrained by `umask 077`, names the target and
backend, and is fully validated before reset performs its first UCI write.

Connection ownership remains in OpenWrt netifd. The adapter does not invoke
`--start-network`, `--stop-network` or `--modify-profile`; after UCI commit the
core asks netifd to restart only the selected target. If a requested
`ipv4v6` bearer does not become ready, QMI makes one explicit retry with IPv4
and records IPv4 as the effective cached profile when it succeeds. Other IP
families are not silently changed.

## Native MBIM adapter

`/usr/libexec/apn-autoconfig-mbim` follows the same shape: `capabilities` and
`identity <device>`, the same v1 identity TSV, the same exit classes and the same
per-device identity lock namespace. It issues only the read-only `umbim`
`subscriber`, `home` and `registration` queries and never starts, stops or
reconfigures a bearer.

Three MBIM-specific rules have no QMI equivalent and are normative in
[`mbim-contract-v1.md`](mbim-contract-v1.md): `umbim`'s exit status carries
modem state rather than failure, so validated stdout is authoritative; the
adapter must never close a control session netifd opened for a live bearer; and
`umbim connect` accepts exactly one authentication protocol, so a normalized
`pap-or-chap` profile expands into bounded `chap`-then-`pap` attempts and the
effective value is what gets cached.

The backend owns the same five netifd options as QMI, but `pdptype` takes MBIM's
`ipv4` rather than qmi.sh's canonical `ip`, and readiness is observed on the
dynamic `${interface}_4` / `${interface}_6` interfaces `mbim.sh` publishes.

## Native AT identity

AT identity is implemented in `apn-autoconfig-modem` from 0.14.0, as
`at-identity --modem <id>`. It resolves the port by role, holds the AT port lock
for the whole read and emits the v1 identity TSV below, unchanged from what the
QMI and MBIM adapters produce.

### Which component answers the APN engine: decided in 0.15.0

There is deliberately **no `/usr/libexec/apn-autoconfig-at`**, and this is a
decision rather than an omission.

0.14.0 left it open because the engine only ever asks about a configured netifd
target, and an AT-managed modem had none. Two candidates were recorded, to be
chosen against a real consumer rather than in the abstract:

1. **A thin `/usr/libexec/apn-autoconfig-at`** with `capabilities` and
   `identity <device>`, matching the QMI and MBIM adapters exactly. Uniform, and
   the engine's dispatch needs no special case. But it puts a second
   implementation of AT port resolution and reply parsing in the core package,
   competing for the same tty as the modem package's.
2. **The engine asks the modem package**, `at-identity --modem <id>`. One
   implementation, one owner of the port lock, and the modem package already
   owns hardware access — the engine already delegates the power cycle to it. It
   costs a second dispatch shape in the engine, and a harder dependency on the
   modem package for that target class.

**The second is chosen.** 0.15.0 brings the caller — an `apn_atdial` target —
and with it the deciding fact: the protocol handler must hold the AT port for
the whole dial, so a third component parsing AT replies on the same tty would be
contending with both the modem package and the handler. One resolver, one parser
and one owner of the port lock is worth a second dispatch shape in the engine.

The engine therefore resolves an AT-managed target in two steps, both existing
commands: `apn-autoconfig-modem resolve --interface <section>` for the modem
identity, then `apn-autoconfig-modem at-identity --modem <id>` for the v1
identity TSV. The dependency on the modem package for this target class is real
and is declared, not implied.

One 0.14.0 obligation was **not** deferred with the decision and is met: the QMI
adapter's AT fallback takes the shared AT port lock, so two components of this
project cannot write to one `ttyUSB` at the same time.

### Properties fixed by that decision

AT is an **identity-only backend, permanently**. Its capability map reports
`identity: true` and `profile_read`, `profile_write` and `profile_apply` all
false, and that is not a maturity statement to be revised later. An AT-managed
modem still receives its APN the same way every other target does: the engine
writes the netifd options the target's protocol declares, and the protocol
handler applies them. There is no AT profile-write path to implement, because
the profile does not belong to the transport.

`AT+CGDCONT?` is read for diagnostic display only — it shows what the modem
currently holds, which is exactly the thing worth seeing when it disagrees with
UCI. It must not be reported as `profile_read`: that capability means the
backend can read the profile fields **it owns**, and this backend owns none.

The read-only command allowlist is fixed, and nothing outside it is accepted
from UCI, the environment, the GUI or another caller:

```text
AT            ATE0          AT+CGMI       AT+CGMM       AT+CGMR
AT+CGSN       AT+CIMI       AT+CCID       AT+QCCID      AT+ICCID
AT+COPS?      AT+COPS=3,2   AT+CEREG?     AT+CGREG?     AT+CREG?
AT+CGDCONT?   AT+CSQ        AT+CESQ
```

`AT+COPS=3,2` is the one entry that writes: it selects the numeric PLMN
presentation format for the session, because `AT+COPS?` otherwise returns a
display name whose spelling varies by firmware and cannot be matched. It changes
no stored modem setting.

Field mapping follows the QMI adapter wherever a choice already exists, so that
the matcher and the GUI see one shape regardless of transport:

- `operator_id` is left **empty**. No standard AT command reports the SIM's home
  PLMN, and the IMSI cannot be split into MCC/MNC without knowing the MNC length
  for that MCC. The matcher already handles this: it tests the database row's
  MCC-MNC as an IMSI prefix when `operator_id` is empty, so the row supplies the
  length and both five- and six-digit rows are evaluated. A roaming serving PLMN
  is never presented as the home operator.
- `serving_operator_id` comes from the numeric `AT+COPS?` reply and
  `access_technologies` from its `<AcT>` field.
- `registration_state` and `roaming` come from the first of `AT+CEREG?`,
  `AT+CGREG?`, `AT+CREG?` that answers, mapping `<stat>` 1 to home, 5 to
  roaming, 2 to searching, 3 to denied and 0 to idle. A denied registration is
  permanent and must not be reported as retryable.

  `<stat>` **6, 7, 9 and 10 also mean registered.** 6 and 7 are SMS-only on the
  home and visited network; 9 and 10 are "CSFB not preferred" on the same pair.
  All four map to home or roaming accordingly. This is not a specification
  curiosity: a device attached over LTE or 5G with no CS domain reports exactly
  this from `AT+CREG?`, and the first modem measured for this contract did.
  Omitting them reports a fully registered modem as unregistered whenever the
  source that answers is the one using them, which is also why `CEREG` and
  `CGREG` are preferred over `CREG` rather than merely listed first.

  9 and 10 were missing from the shipped 0.14.x mapping and were fixed in
  0.15.0. The failure was silent in the worst way: an unmapped value falls
  through to the next source, and a modem answering 9 from all three ends as
  `unknown` — the same class of mistake 6 and 7 were added to correct.
- `signal_quality` uses `AT+CESQ` RSRP through the same -120 dBm to -80 dBm
  mapping the QMI adapter documents, falling back to `AT+CSQ` RSSI through the
  same -110 dBm to -50 dBm scale. `AT+CSQ` value 99 means unknown and leaves the
  field empty rather than reporting zero signal, and `AT+CESQ` uses 255 for the
  same purpose per field. The parser must accept **more than the six standard
  `CESQ` fields**: a 5G-capable modem appends NR fields, which are frequently
  255 while the LTE fields carry real values, so a strict six-field match would
  discard a usable reading.

ICCID uses an ordered attempt list — the standard spelling first, then the
vendor variants — advancing only on an immediate command error. A timeout stops
the sequence for that port, because a port that did not answer the first read is
not going to answer a differently spelled one.

As everywhere else, unknown values are empty rather than guessed, and a missing
optional field never invalidates otherwise valid SIM identity.

QMI does not inherit ModemManager's `allow_roaming` control. Until a portable,
tested QMI policy mapping exists, the GUI keeps that control visible but
disabled with an explanation, and the command fails with target-contract exit
code 4 without mutation. Status still reports the observed roaming state, but
uses `roaming_policy: "unsupported"`; APN operations ignore any stale
`network.<interface>.allow_roaming` value owned by another connection stack.

## The AT-dial backend (`apn_atdial`)

0.15.0 adds the first backend whose netifd protocol this project ships itself.
Its full behaviour is normative in [`atdial-contract-v1.md`](atdial-contract-v1.md);
this section states only what the engine must know.

A target whose `proto` is `apn_atdial` selects backend `atdial`. It differs from
the three that came before in exactly two ways that reach this contract.

**Identity is delegated, not adapted.** There is no
`/usr/libexec/apn-autoconfig-atdial`. The engine resolves the modem identity
bound to the section with `apn-autoconfig-modem resolve --interface <section>`
and then reads identity with `apn-autoconfig-modem at-identity --modem <id>`,
which returns the same v1 identity TSV every other backend produces. Capability
is `identity: true` when both commands are available and the modem package can
reach the modem; `backend-command-unavailable` otherwise.

**The profile is applied, never written.** `profile_read` and `profile_write`
are permanently false and `profile_apply` is true. The engine owns `apn`,
`username`, `password`, `auth` and `pdptype` — the same five options as QMI and
MBIM, so baseline capture and restore reuse the existing branch with no change
to the v3 baseline format — and the protocol handler applies them on the next
interface start. Nothing is written into the modem as owned state.

`pdptype` takes canonical 3GPP values: `IP`, `IPV6`, `IPV4V6`. This differs from
QMI's `ip` and MBIM's `ipv4` because it is passed to `AT+CGDCONT` verbatim,
where nothing else is valid. The engine writes the canonical spelling; the
handler normalises a hand-written one.

Roaming policy is supported through the single `allow_roaming` option, so
`roaming_policy_read` and `roaming_policy_write` are both true. It is not the
`allow_roaming`/`allow_partner` pair MBIM uses: there is no partner concept
here, and the handler enforces the policy itself by refusing to dial on a
roaming registration. As with MBIM, the GUI's labels for this control are
backend-specific.

Implementation and validation state are reported per path rather than per
backend, because they genuinely differ: the RNDIS/ECM dial is `stable`/`hardware`
on the strength of the FM350-GL gate, while the Intel XMM tail is
`alpha`/`synthetic` until such a device has actually been driven.
