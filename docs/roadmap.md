# Architecture roadmap

This roadmap records public release milestones. It describes intended outcomes,
not implementation proposals or evaluations of other projects. Hardware findings
may change the sequence, but the safety invariants remain binding: never mutate
an ambiguous target, never claim an unavailable capability, verify connectivity
before keeping a profile, and restore the previous profile after failure.

The `apn-autoconfig` package keeps its narrow responsibility: identify the SIM
and registration context for a configured cellular target, select and apply an
APN profile, verify connectivity, and roll back safely. The project will grow
toward 1.0 through additional first-party packages for modem provisioning,
connection control and eSIM lifecycle rather than folding those responsibilities
into the APN engine. All project packages must be built from source where
applicable and distributed through the signed repository; the LuCI frontend
remains an optional consumer of versioned machine APIs.

## 0.9.0 — adapter foundation

Released. Introduced stable target discovery, explicit capabilities, the
versioned GUI-independent API, per-target state, fail-closed mutation and the
complete ModemManager backend.

## 0.9.1 — native QMI adapter

Released. Added native QMI identity and profile handling for configured netifd
targets, exact rollback, dual-stack fallback and hardware evidence for the
Huasifei WH3000 Pro with Quectel RM520N-GL.

## 0.9.2 — rollback and backend hardening

Released. Hardened signal handling, QMI rollback, root-only state validation,
canonical device paths, baseline ownership, shared profile plumbing and QMI
data-interface readiness after a physical modem reset.

## 0.9.3 — native MBIM APN adapter

Planned next. Add MBIM SIM and registration identity, backend-owned profile
capture/write/restore, and correct readiness handling for dynamically created
IPv4/IPv6 data interfaces. The release requires the normal fixture, official
SDK, package lifecycle and real-hardware evidence gates. Automatic modem
provisioning and eSIM management remain out of scope for this release.

## 0.9.4 — generic AT identity and manual profile input

Extend bounded, read-only AT identity collection to selected configured
AT-managed targets, including stable port resolution and normalized ICCID,
IMSI, home/serving PLMN and registration state. Add a supported manual APN
profile path that uses the same write, connectivity-verification and rollback
discipline as database-selected profiles.

## 0.9.5 — modem inventory and automatic provisioning

Add a first-party modem inventory and provisioning service. It will identify
an unconfigured attached modem by stable hardware identity, classify an
implemented control path, create or update only its owned netifd section, and
hand APN selection to `apn-autoconfig` before enabling automatic connection.
Stock QMI/MBIM netifd protocols remain preferred where available; selected
AT-managed devices may use separately packaged protocol support.

## 0.9.6 — connection control and LuCI connection tab

Publish a narrow connection-control API and add a dedicated LuCI tab for modem
and bearer status, signal quality, connect/disconnect/reconnect and supported
reset operations. Existing signal and modem-reset presentation moves out of
the APN tab. Board-specific physical controls remain optional and capability
gated.

## 0.9.7 — eSIM lifecycle and live APN reconciliation

Add source-built eSIM support around `lpac`, distributed through the signed
project repository. Provide bounded profile inventory and lifecycle actions,
plus a serialized workflow that re-reads the active SIM and invokes targeted
APN reconciliation after a successful profile switch so data connectivity can
return without a router reboot. Add a dedicated LuCI eSIM tab.

## 1.0 — stable standalone mobile-connectivity suite

Stabilize the package boundaries and machine APIs for the APN engine, provider
database, modem provisioning/control, eSIM lifecycle and the unified optional
LuCI frontend. The frontend presents separate APN, connection and eSIM tabs;
provider-database updates remain on the APN tab. The 1.0 compatibility target
includes configured ModemManager, QMI and MBIM paths, selected AT-managed
devices, and a practical Fibocom FM350-GL control path, each advertised only at
its demonstrated implementation and hardware-validation level.

The 1.0 gate includes upgrade and removal safety, multi-entry-point locking,
SIM/eSIM transition recovery, modem hotplug and re-enumeration, coexistence of
multiple control stacks, signed installation without untrusted packages, and
documented hardware evidence for every stable support claim.
