# Modem contract v1

This document defines the read-only inventory, stable identity, discovery
evidence hierarchy and control-owner model implemented by
`apn-autoconfig-modem` starting with 0.10.0. It is the modem-control analogue
of [`backend-contract-v1.md`](backend-contract-v1.md); together they let the
APN engine keep its narrow contract while a lower layer owns modem inventory
and hardware-facing operations, per [`architecture.md`](architecture.md).

The scope has widened once per milestone, each time explicitly: 0.10.0 was
read-only discovery plus a bounded reset; 0.11.0 added creation and ownership of
project-owned netifd sections together with connect/disconnect/reconnect; 0.13.0
stopped gating those three on who created the interface; 0.14.0 adds the AT
transport, AT identity and the reset-method contract. It still does not mutate
an APN profile — that stays with the APN engine — and does not manage eSIM.
Later milestones extend this contract explicitly rather than silently widening
it, and sections below name the release that introduced a rule wherever the rule
replaced an earlier one.

## Modem record schema v1

`apn-autoconfig-modem inventory-json` returns:

```json
{
  "version": "v1",
  "modems": [
    {
      "modem_id": "usb-serial:1-1.2:...",
      "evidence_tier": "usb-serial|imei|weak-vidpid",
      "usb_path": "1-1.2",
      "vendor_id": "2c7c",
      "product_id": "0801",
      "control_device": "/dev/cdc-wdm0",
      "data_device": "wwan0",
      "at_device": "/dev/ttyUSB2",
      "protocol": "qmi|mbim|at|modemmanager|unknown",
      "manufacturer": "Quectel",
      "model": "RM520N-GL",
      "firmware_revision": "RM520NGLAAR03A01M4G",
      "implementation_state": "stable",
      "validation_state": "synthetic|hardware",
      "hardware_validated": false,
      "owner_state": "none|netifd-direct|modemmanager|transitioning|conflicting",
      "netifd_interface": "wwan",
      "reset_method": "gpio|modemmanager|at|none",
      "capabilities": { "inventory": true, "at_identity": false, "reset": false },
      "first_seen": "2026-08-13T00:00:00Z",
      "last_seen": "2026-08-13T00:00:00Z",
      "ambiguous": false,
      "ambiguity_reason": ""
    }
  ]
}
```

`status-json --modem <modem_id>` returns one such record, or a `not_found`
error object when the ID no longer resolves to a present device.

`control_device`, `data_device` and `at_device` are **attributes**, not
identity: they may change across re-enumeration and must never be compared
across scans to decide whether two records describe the same physical modem.
Only `modem_id`, derived per the evidence hierarchy below, is stable.

`manufacturer`, `model`, `firmware_revision`, `reset_method` and
`capabilities.at_identity` were added in 0.14.0. They are an additive extension
of the v1 schema, not a new version: every field a v1 consumer already reads
keeps its name and meaning, and a consumer that ignores the new fields behaves
as before. The three identity strings come from `AT+CGMI`, `AT+CGMM` and
`AT+CGMR` and are empty whenever no AT identity was obtained; they are display
and quirk-keying evidence, never identity, because nothing in them
distinguishes two identical modems in two slots.

`capabilities.reset` is true when at least one reset method's preconditions are
met for this record, and `reset_method` names the one that would run. See
[Reset methods](#reset-methods) below. `capabilities.at_identity` is true only
when exactly one AT port resolved by role for this record and the current owner
permits the project to use it.

Capability, implementation maturity and hardware-validation evidence stay
separate exactly as in the APN backend contract; an installed classifier is
not hardware support. Maturity describes this implementation and is therefore
the same for every record; evidence describes the protocol that was classified,
so QMI, MBIM and AT all report `hardware` — the last of them since the 0.14.0
gate — while unclassified devices report `synthetic`. As with the APN backends, that evidence comes from one modem on one
board and does not transfer to other hardware by itself. These fields must be
kept current: a stale `experimental` understates a validated implementation just
as badly as an unearned `stable` overstates one.

## Discovery evidence hierarchy

Strongest to weakest. A weaker tier is used only when a stronger one is
unavailable for the device class:

1. **`usb-serial`: USB topology + device serial.** The physical bus/port chain
   (from sysfs) combined with the USB device's own serial number
   (`idVendor`/`idProduct`/`serial`, when the device exposes one). Stable
   across reboots and modem power cycles as long as the modem stays in the
   same physical port.
2. **`imei`: modem-reported hardware identity.** Used only when the device
   exposes no USB serial. Read through the same bounded, read-only backend
   calls the APN engine already uses for identity (QMI `--get-imei` or the
   AT fallback), never through free-form AT. Survives port changes but
   requires the modem to be enumerable and responsive. A modem that exposes no
   USB serial and no QMI/MBIM control channel therefore reaches a strong tier
   only through AT, and only after resolution has run: it is first recorded at
   `weak-vidpid` and upgraded to `imei` once identity is obtained. This is not
   circular, but it does mean such a modem is weakly identified until something
   asks for its identity, and two of them would stay ambiguous until then.
3. **`weak-vidpid`: bus/port + vendor:product only.** Used only for initial
   classification when neither `usb-serial` nor `imei` evidence is available.
   Never sufficient alone to rebind an existing record to a new `/dev` name
   after re-enumeration.

Independent of which tier established `modem_id`, **same-USB-device
correlation** binds `control_device`, `data_device` and `at_device` together
using the shared sysfs USB devpath ancestor, exactly like
`usb_device_path`/`control_usb_device` in `apn-autoconfig-qmi`. This is an
attribute-binding step applied within a tier, not a fourth tier.

Two concurrently present candidates that can only be distinguished by
`weak-vidpid` evidence are **ambiguous**: both records get `ambiguous: true`, no
`netifd_interface` binding is attempted for either, and no bounded operation
may target either `modem_id` until the ambiguity resolves (fewer candidates,
or one gains stronger evidence). This mirrors the fail-closed rule already
proven for APN target selection.

ModemManager inventory is collected before any optional direct QMI identity
probe. A USB device already claimed by ModemManager keeps ModemManager as its
only control reader during the scan; the inventory must not issue `uqmi`
against it. If ModemManager discovery fails or returns an unparseable non-empty
inventory, ownership is uncertain and no direct QMI identity probe runs during
that scan. Both USB interface paths and physical USB device-root paths reported
by ModemManager or stored in netifd `device`/`devpath` normalize to the same
physical record. Direct QMI
inventory shares the APN adapter's per-control-device
identity lock and degrades to weak evidence when that bounded lock cannot be
obtained. Every external backend query is bounded, including when the platform
has no external `timeout` command. More than one correlated control channel,
data device or netifd section is ambiguity, not an enumeration-order choice.
Until 0.14.0, multiple AT ports were terminal ambiguity for an AT-only modem.
That rule was correct about cross-device ambiguity and wrong about this case:
several tty nodes correlated to **one** proven USB device are not two candidate
modems, they are one modem exposing several ports, of which most are not command
channels at all. Applying the fail-closed rule there made every ordinary
multi-port modem permanently unusable rather than safe. Since 0.14.0 such ports
are resolved by role (see [AT port resolution](#at-port-resolution)) and the
record stays unambiguous. Ambiguity **between** USB devices is unchanged and
still fails closed.

## Control-owner states

| State | Meaning |
|---|---|
| `none` | No active control session observed: nothing holds this modem's data or control device and no ModemManager `Modem` object exists for it. A netifd section may still be **bound** to the modem and reported in `netifd_interface` — see below. |
| `netifd-direct` | A netifd protocol (`qmi.sh`, `mbim.sh`, ...) holds the session directly against this modem's data/control device; no ModemManager instance manages it. |
| `modemmanager` | ModemManager has an active `Modem` object for this device, independent of whether a netifd `mm` proto session is also up. |
| `transitioning` | A coordinator operation (`action-start reset`) is currently running against this `modem_id`. This is a **display-time overlay**, never a persisted state: discovery stays read-only and authoritative, so `status-json`/`inventory-json` compute `none`/`netifd-direct`/`modemmanager`/`conflicting` from currently observed backend state and substitute `transitioning` only while the coordinator's own action-status for that `modem_id` reports busy. |
| `conflicting` | Both ModemManager and direct/netifd-direct evidence were observed for the same `modem_id` in one scan, or two records independently claim the same physical device. Fails closed: no bounded operation may start while `conflicting`. |

A bounded operation may start only from `none`, `netifd-direct` or
`modemmanager`. It may never start while the record is `conflicting`, and the
coordinator's own per-modem lock (see below) already prevents starting a
second operation while one is `transitioning`.

### A binding is not a session

Every state above describes an **observed** control session, never configuration
that anticipates one. The two are routinely different, and one case is common
enough to be normative: a netifd section with `proto='modemmanager'` delegates
the session to a daemon, so while no ModemManager `Modem` object exists for that
device the section holds nothing and the state is `none`, not `netifd-direct`.
`netifd-direct` names one specific mechanism — a netifd protocol handler holding
the control device itself — and a section that never opens one cannot satisfy it.

`netifd_interface` still reports the bound section in that case, because the
binding remains true and everything else built on it depends on it: `resolve
--interface` still maps the section to this `modem_id`, provisioning still
refuses to create a second section with `already_configured`, and a reset still
cycles that exact interface. Only the ownership claim is withdrawn.

This distinction was cosmetic while `owner_state` was informational. Since
0.14.0 it is not: `netifd-direct` is one of the states that permits direct AT
port access, so naming a session that does not exist would grant access on the
strength of a `qmi.sh` handler that was never running. Reaching the same
permission through `none` is the honest route — nothing holds the ports, and
nothing is claimed to.

Neither state is a durable licence. Ownership is re-read under the operation's
own locks before any AT port is opened, because a modem that is unowned when it
is scanned can be claimed moments later — on the reference router ModemManager
publishes a freshly attached modem only after it has finished probing every
port, so unowned-then-owned is the ordinary sequence rather than a race.

## AT port resolution

Added in 0.14.0. A modem commonly exposes three to seven tty nodes, of which
some are DM, NMEA, GNSS, audio or debug ports rather than command channels.
Enumeration order says nothing about which is which, and the node names are
volatile, so a port is selected by **observed role** and never by index.

Candidate ports are first reduced to those correlated to the record's own USB
device by the shared sysfs ancestor, exactly as `at_device` already is. This is
what keeps two simultaneously present modems separate: correlation happens
before any probe, so a probe is never issued to a port belonging to the other
modem, regardless of how the kernel numbered them.

Each remaining candidate is then probed in two phases, under the port lock and
within the bounded executor:

1. `ATE0` followed by a bare `AT`. No reply, a timeout or anything other than a
   final `OK` removes the candidate. A timed-out port is removed immediately and
   is not retried with alternate spellings: it is not a command channel, and
   repeating the attempt only repeats the delay. The parser must tolerate a
   leading echo of the command itself on this first exchange, because `ATE0` has
   not taken effect yet when it is echoed — and echo state is per port, not per
   modem: one modem can present one port with echo off and another with echo on
   at the same moment.
2. `AT+CGMM`. A candidate that answers phase 1 but returns no plausible model
   string is a port that speaks AT without being the control channel, and is
   removed.

Probing is strictly read-only in the project sense: it writes to the port,
because AT has no other way to ask a question, but it changes no modem, UCI or
filesystem state. `ATE0` is session-scoped echo suppression required to parse
replies at all. Discovery must not acquire a port it does not then release, and
must not persist anything beyond the resolution cache described below.

Zero surviving candidates means `capabilities.at_identity` is false and the
record carries no AT evidence. Several surviving candidates on one proven USB
device are **redundancy, not ambiguity** — they are the same modem answering on
more than one channel, so the answers agree — and the lowest-indexed survivor is
selected deterministically. The selection is cached per `modem_id` and
revalidated before reuse; a cached node that is absent, no longer correlated to
the same USB device, or no longer passing phase 1 is discarded and resolution
runs again.

### Resolution is lazy, and its cache is negative as well as positive

A sweep is expensive, and not marginally so. Ports that accept a write and never
answer are the common case rather than the exception — on the first modem
measured for this contract, five of seven ports behaved that way — so a full
sweep costs the per-port bound multiplied by the number of dead ports, and a
modem with no command port at all costs the maximum every time.

Two rules follow, and both are normative rather than performance advice, because
LuCI calls inventory on page load and a synchronous sweep there is a visible
multi-second hang:

- **Discovery does not sweep.** A scan reports what is already cached, and
  `capabilities.at_identity` is false until a resolution has actually happened.
  Resolution is triggered by a request that needs AT identity, not by
  enumeration.
- **Failures are cached too.** A port that failed phase 1 is recorded as such
  and skipped on later sweeps, keyed by its **stable USB interface path**, never
  by the volatile tty index. Keying by index would let a re-enumeration silently
  apply one port's verdict to a different port; keying by interface path makes
  re-enumeration invalidate the entries that genuinely changed and keep the ones
  that did not.

Resolution never runs at all while `owner_state` is `modemmanager` or
`conflicting`. ModemManager holds the command port of the modems it manages,
and probing underneath it is exactly the race the single-owner invariant
forbids. This is the same gate that already precedes a direct `uqmi` probe.

This restraint is deliberate rather than forced, and the distinction is worth
recording because the temptation to relax it is concrete. A multi-port modem
under ModemManager typically leaves a *second* AT port apparently free, and
probing it usually appears to work. It is still not permission: ownership is of
the modem, not of one node. Firmware may serialize AT internally across ports,
unsolicited result codes can reach the wrong reader, and which port ModemManager
holds varies by version and plugin, so a rule built on observing the free one is
built on an accident. Nothing is lost by refusing — a ModemManager-owned modem
already has a native identity path — and what would be lost by allowing it is
the single-owner invariant itself. When a later milestone genuinely needs the
port under ModemManager, the answer is a bounded ownership transition, not an
unannounced second reader.

### Quirk table

Vendor divergence is carried by a table keyed by `manufacturer` and `model`,
with `firmware_revision` available for entries that genuinely need it. Its
default is empty, and an empty entry means **not tested, so not offered** —
never "probably works like the others".

The table is not needed to establish identity, and that ordering matters: the
3GPP core reads (`AT+CGMI`, `AT+CGMM`, `AT+CGMR`, `AT+CGSN`, `AT+CIMI`,
`AT+COPS?`, `AT+CEREG?`/`AT+CGREG?`/`AT+CREG?`, `AT+CGDCONT?`, `AT+CSQ`) are
uniform across vendors, so the bootstrap that learns *which* modem this is uses
no vendor knowledge. Reads that are standard in intent but divergent in
spelling — ICCID being the practical case — use an ordered attempt list rather
than a table entry, advancing on an immediate command error and stopping on a
timeout. Only capabilities beyond identity belong in the table.

## Reset methods

Added in 0.14.0. `modem-reset` is one capability with several implementations.
The method is chosen by the record's current control owner, so that the reset is
always performed by whoever legitimately holds the modem:

| Method | Preconditions | Applicable owner |
|---|---|---|
| `gpio` | a supported board integration package is installed, its GPIO path is validated and writable, and the administrator has pinned this record's strong `usb-serial:` or `imei:` identity as `apn-autoconfig-modem.main.reset_modem_id` | any — board power is out of band and touches no control channel |
| `modemmanager` | ModemManager has a `Modem` object for this record and reports reset support for it | `modemmanager` |
| `at` | exactly one AT port resolved by role and the project holds the port | `none`, `netifd-direct` |

`gpio` is preferred wherever its preconditions hold, which preserves the
released Huasifei behaviour unchanged. A board-wide GPIO is still never inferred
to control every modem merely because several are present, so a second modem on
the same board does not inherit the pinned modem's reset.

Delegating to ModemManager rather than refusing under it is deliberate. The
alternative — refusing a soft reset whenever ModemManager is present — would
have encoded one deployment's shape into the contract, and would leave a
ModemManager user with no reset at all on a board without GPIO. Asking the owner
to run its own reset keeps the single-owner invariant with no configuration
carved out.

Each method carries its own evidence. A method validated on hardware promotes
only itself; `capabilities.reset` being true says a method's preconditions hold,
not that this modem's reset has ever been observed to work.

`AT+CFUN=1,1` has one property no other command in this contract shares: **it
takes the port away as it succeeds.** The modem begins resetting and
re-enumerates, so the write frequently returns no final `OK` at all. A missing
or truncated reply is therefore an expected outcome of success, not a transport
failure, and the terminal result is decided the same way the GPIO path already
decides it — by bounded re-enumeration and the return of the same stable
identity under the pre-reset owner. Treating the vanished port as an error would
report a false failure on every successful soft reset.

A soft reset that leaves the modem wedged does not automatically escalate to a
board power cycle; see the deferred decision in
[`architecture.md`](architecture.md).

## Coordinator and lock ordering

`apn-autoconfig-modem` composes with the existing APN engine's global operation
lock (`acquire_lock` in `apn-autoconfig`) using one mandatory order:

1. acquire or prove ownership of the global APN operation lock;
2. acquire the selected per-`modem_id` lock;
3. revalidate presence, ownership and reset capability after both locks;
4. perform the guarded power-cycle and wait for the same stable identity to
   return under the pre-reset control owner without ambiguity;
5. release the modem lock, finish targeted APN reconciliation while retaining
   the global lock, then release the global lock.

A direct modem reset acquires both locks itself. The compatibility shim passes
its PID and the modem package accepts borrowed ownership only when that exact
live PID is recorded in the APN lock. Future provisioning and eSIM operations
must use the same global-to-specific order; reverse acquisition is forbidden.

### The AT port lock

Added in 0.14.0 as a third and innermost level: **global APN operation lock →
per-`modem_id` lock → per-AT-port lock**, released in reverse. A read-only
identity transaction that needs no coordinator operation acquires the port lock
alone, exactly as the QMI adapter's per-control-device identity lock already
works, and shares that adapter's lock namespace so the two cannot overlap on one
device.

The lock is mandatory, not advisory. An implementation that waits, fails to
acquire and then proceeds anyway is forbidden even for a read: a tty is
effectively exclusive, and an interleaved reader corrupts both its own reply
stream and the holder's. This matters most for the operations that come later —
an eSIM APDU exchange holds an open logical channel across many commands, and a
probe landing inside it breaks the channel rather than merely losing a reply.

The lock uses the representation below, unchanged. It is keyed by the resolved
port's canonical device path, so two modems probed at once take two different
locks and do not serialize against each other at this level. They do still
serialize at the global level; that is the deferred decision recorded in
[`architecture.md`](architecture.md).

### Lock representation

Since 0.10.1 a lock is a **regular file whose first line is the owner PID**,
created with `ln` from a temporary file that already contains the PID. The
name and its owner therefore become visible in one atomic step. `mkdir`
followed by a separate PID write is forbidden: it leaves a window in which the
lock exists with no recorded owner, and every waiter that treats a missing
owner as proof of a crash will delete a live lock and proceed. That window was
the cause of two intermittent 0.10.0 defects — a duplicated background worker
and an accepted operation reported as a dead one.

A lock whose owner is not alive may be reclaimed only while holding an
`ln`-guarded `<lock>.reclaim` mutex, and the owner must be re-read inside that
guarded section so a racing reclaimer cannot delete a lock another process has
just legitimately taken.

`apn-autoconfig`, `apn-autoconfig-qmi` and `apn-autoconfig-modem` implement the
identical protocol. This is a cross-package requirement, not a style choice:
the global APN operation lock and the per-device QMI identity lock are shared
namespaces, and two different representations at one path would not exclude
each other reliably.

0.10.0 represented a lock as a directory containing a `pid` file. All three
implementations still honor a live owner in that shape and reclaim a dead one,
so an upgrade cannot deadlock against a leftover. Because a 0.10.0 process
still uses the old two-step protocol, upgrade every suite package together
rather than mixing 0.10.0 and 0.10.1 binaries against a shared lock.
`action-start`/`action-status` on
`apn-autoconfig-modem` mirror the existing `apn-autoconfig` background-action
contract (`state.tsv` v2 record, `running/success/blocked/retryable/failed`,
busy/external detection) so LuCI can reuse the same polling pattern for both.

## Compatibility mapping

`apn-autoconfig modem-reset` (and `action-start modem-reset`) keep their
released behavior and exit codes. When `apn-autoconfig-modem` is installed,
the engine resolves the modem bound to its selected target
(`apn-autoconfig-modem resolve --interface <section>`) and delegates the
power-cycle-and-reidentify phase to `apn-autoconfig-modem reset --modem <id>`.
The modem package restarts netifd only after the original control owner has
returned; for a ModemManager target, the APN engine then waits boundedly for a
readable primary SIM and the selected interface before running `reconcile`
under the same global lock.
When `apn-autoconfig-modem` is not installed, the engine's original inline
power-cycle path runs exactly as released. When it is installed but cannot
prove one reset-capable binding, the operation fails closed; it never silently
falls back after the new ownership boundary was selected. This keeps the
package dependency soft for 0.10.0 per
`architecture.md`/`development-handoff.md` — a later release may retire the
inline path once the new coordinator has hardware evidence.
