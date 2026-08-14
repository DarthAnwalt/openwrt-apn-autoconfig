# Modem contract v1

This document defines the read-only inventory, stable identity, discovery
evidence hierarchy and control-owner model implemented by
`apn-autoconfig-modem` starting with 0.10.0. It is the modem-control analogue
of [`backend-contract-v1.md`](backend-contract-v1.md); together they let the
APN engine keep its narrow contract while a lower layer owns modem inventory
and hardware-facing operations, per [`architecture.md`](architecture.md).

`apn-autoconfig-modem` is read-only discovery plus a bounded reset operation
in 0.10.0. It does not create netifd sections, mutate a profile or manage
eSIM. Every rule below binds only that scope; later milestones extend the
contract explicitly rather than silently widening it.

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
      "implementation_state": "experimental",
      "validation_state": "synthetic",
      "hardware_validated": false,
      "owner_state": "none|netifd-direct|modemmanager|transitioning|conflicting",
      "netifd_interface": "wwan",
      "capabilities": { "inventory": true, "reset": false },
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

`capabilities.reset` is true only when a supported board integration package
(the Huasifei GPIO integration, currently) is installed, the record's
`protocol` is one this release can safely power-cycle and re-identify, and the
administrator has pinned that record's strong `usb-serial:` or `imei:` identity
as `apn-autoconfig-modem.main.reset_modem_id`. A board-wide GPIO is never
inferred to control every QMI modem merely because several are present.
Capability, implementation maturity and hardware-validation evidence stay
separate exactly as in the APN backend contract; an installed classifier is
not hardware support.

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
   requires the modem to be enumerable and responsive.
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
Multiple AT ports are terminal ambiguity for an AT-only modem. On a modem with
a separately proven QMI/MBIM control channel they suppress only the optional
`at_device` attribute; they do not invalidate that control binding, and no AT
operation is allowed until a future backend identifies a port by role.

## Control-owner states

| State | Meaning |
|---|---|
| `none` | No active control session observed: no netifd interface bound and no ModemManager `Modem` object for this device. |
| `netifd-direct` | A netifd protocol (`qmi.sh`, `mbim.sh`, ...) holds the session directly against this modem's data/control device; no ModemManager instance manages it. |
| `modemmanager` | ModemManager has an active `Modem` object for this device, independent of whether a netifd `mm` proto session is also up. |
| `transitioning` | A coordinator operation (`action-start reset`) is currently running against this `modem_id`. This is a **display-time overlay**, never a persisted state: discovery stays read-only and authoritative, so `status-json`/`inventory-json` compute `none`/`netifd-direct`/`modemmanager`/`conflicting` from currently observed backend state and substitute `transitioning` only while the coordinator's own action-status for that `modem_id` reports busy. |
| `conflicting` | Both ModemManager and direct/netifd-direct evidence were observed for the same `modem_id` in one scan, or two records independently claim the same physical device. Fails closed: no bounded operation may start while `conflicting`. |

A bounded operation may start only from `none`, `netifd-direct` or
`modemmanager`. It may never start while the record is `conflicting`, and the
coordinator's own per-modem lock (see below) already prevents starting a
second operation while one is `transitioning`.

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
