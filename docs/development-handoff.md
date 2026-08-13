# Development handoff

This document is the shortest safe entry point for a new maintainer or coding
assistant. Read it together with [`backend-contract-v1.md`](backend-contract-v1.md),
[`testing-0.9.2.md`](testing-0.9.2.md) and [`roadmap.md`](roadmap.md) before
changing runtime behavior. The README is the user-facing reference; the
changelog records shipped differences rather than future intentions.

## Current core boundary and project direction

The released `apn-autoconfig` core identifies the SIM and registration context,
ranks normalized APN profiles, applies only the profile fields owned by the
selected connection backend, verifies Internet connectivity, and rolls back on
failure. That package remains a narrow APN engine rather than becoming a
general modem manager.

The engine supports an already configured cellular target. It does not create
the user's `network` section, install every possible protocol stack, or guess
between multiple equally capable targets. Runtime discovery and implementation
evidence are separate: recognizing `mbim` or `fibocom` must never imply that a
writable adapter exists.

The broader first-party project is planned to grow toward 1.0 with sibling
packages for modem inventory/provisioning, connection control, selected netifd
protocol support and eSIM lifecycle. These packages must consume one another's
narrow machine APIs instead of duplicating APN matching, writing each other's
UCI fields or bypassing netifd bearer ownership. The public sequence is in
`roadmap.md`; unimplemented milestones are not current capabilities.

## Package and file map

- `apn-autoconfig`: GUI-independent POSIX-shell engine, narrow rpcd workers,
  boot worker and internal protocol adapters. ModemManager and QMI adapters
  live in this one package so a travel-router user can replace a configured USB
  modem without selecting another AutoAPN package.
- `apn-autoconfig-providers`: independently versioned generated TSV database.
- `luci-app-apn-autoconfig`: optional consumer of the public machine API. It
  must not reimplement discovery, matching, mutation or rollback.
- `apn-autoconfig-integration-huasifei-wh3000`: optional tested BTN_0/GPIO
  integration and its kernel dependency. It is not a generic button package.
- `files/usr/sbin/apn-autoconfig`: target discovery, backend dispatch, matching,
  state, connectivity verification, rollback and public CLI/JSON API.
- `files/usr/libexec/apn-autoconfig-qmi`: bounded, read-only QMI/SIM identity
  transport. Netifd still owns the QMI bearer.
- `files/usr/libexec/apn-autoconfig-query` and `-control`: narrow LuCI/rpcd
  allowlists. Do not grant LuCI the general-purpose CLI.
- `tests/run-tests.sh`: backend, state, failure, rollback, injection and
  compatibility regression suite.
- `scripts/verify.sh`: required local and CI gate.

## Binding safety invariants

1. Resolve one stable `network:<section>` target before mutation. Zero,
   unavailable or ambiguous targets fail closed with no UCI, interface or
   persistent-state change.
2. Treat `detect`, `detect-json`, `status`, `status-json` and `targets-json` as
   read-only. Every modem transaction reachable from them must be bounded.
3. Capture and atomically persist the complete backend-owned profile baseline
   before the first write. Validate every baseline record before the first
   restore write.
4. Change only backend-owned UCI options and restart only the selected netifd
   interface. Never take ownership of the bearer inside an adapter.
5. Keep a candidate only after real connectivity succeeds through netifd's
   effective L3 device. Restore the exact pre-change profile after every
   candidate failure, interruption or explicit reset.
6. Keep credentials and identifiers out of logs and normal LuCI display.
   Root-owned baseline/cache state uses process-wide `umask 077`; LuCI masks
   ICCID, IMSI and EID until an explicit reveal action.
7. Preserve the operation lock across CLI, LuCI, boot and physical-button
   entry points. Future modem-provisioning and eSIM-switch triggers must join a
   documented serialization model without bypassing or deadlocking this lock.
   Long LuCI actions use bounded background action APIs.
8. Capability, implementation and validation evidence are independent. Never
   mark a backend `stable`/`hardware` from fixture or parser tests alone.
9. Roaming policy is backend-specific. ModemManager may edit its canonical
   netifd option; QMI exposes the observed state but leaves policy control
   disabled because no portable mapping has been validated.
10. Package removal runs `reset-all` and aborts if restoration fails. New state
    formats must remain safely removable and must not corrupt older baselines.

## Public integration surface

External GUIs should use the machine commands, preferably through an
equivalently narrow privileged wrapper:

```text
apn-autoconfig targets-json
apn-autoconfig status-json [--target network:<section>]
apn-autoconfig detect-json [--target network:<section>]
apn-autoconfig action-start reconcile [--target network:<section>]
apn-autoconfig action-status
```

`targets-json` v2 is authoritative for target selection and exact runtime
capabilities. Status/detect v2 include `engine_api: v1`, stable target identity,
backend, effective data device and separate implementation/validation evidence.
Consumers must not infer write support from protocol names or silently switch
to a different target. The full schema and QMI adapter contract are documented
in `backend-contract-v1.md`.

## Adding a backend

Keep the common matcher and rollback algorithm backend-neutral. A new backend
normally requires:

1. discovery normalization and truthful per-operation capabilities;
2. bounded, validated identity collection that separates the SIM home identity
   from the serving network;
3. exact capture/restore of only that backend's owned netifd options;
4. normalized profile mapping for APN, credentials, authentication and IP
   family without shell evaluation;
5. netifd-owned reconnect and common L3 connectivity verification;
6. fixture tests for home, roaming, malformed output, missing dependencies,
   ambiguity, injection, apply, idempotency, failure rollback and reset;
7. official-SDK packaging tests followed by a documented physical hardware
   gate before changing the evidence state.

Do not copy vendor-specific commands into the matcher. Extend or add a narrow
internal adapter and make unsupported operations explicit. RNDIS/ECM describes
a data link, not an APN-control protocol; support depends on the accompanying
control path.

## Required workflow

Before editing, inspect the worktree and preserve unrelated user changes. After
runtime, packaging, LuCI or documentation changes run:

```sh
sh scripts/verify.sh
```

The release gate additionally requires the official OpenWrt 25.12 SDK build,
APK install/upgrade/removal simulation, real hardware tests recorded in the
version-specific testing document, rollback artifacts, and a final installed
package smoke test. A green fixture suite is necessary but not sufficient for
a hardware-support claim.

Release tags are `v<core-version>`. The GitHub workflow rejects a tag that does
not match `PKG_VERSION`, publishes checksummed APK assets, and updates the
signed package repository. Never store the private repository signing key in
the source tree or build artifacts.

## Current development direction

Version 0.9.2 is released. The next implementation task is the bounded native
MBIM APN adapter in 0.9.3; automatic modem provisioning, the connection-control
UI and eSIM lifecycle are explicitly later milestones. The core keeps its
current APN boundary while the repository grows into a signed first-party
package suite. Exact sequencing can change after hardware findings; the safety
invariants above cannot.

At the start of 0.9.3, branch from current `main`, confirm that the README
support matrix still describes shipped behavior, and create a version-specific
MBIM test plan before the first hardware mutation. Preserve the completed
0.9.2 evidence as a historical release record rather than rewriting it for the
new release.
