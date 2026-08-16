# Development handoff

This is the shortest safe entry point for the next implementation task. Read it
with [`architecture.md`](architecture.md), [`backend-contract-v1.md`](backend-contract-v1.md),
[`modem-contract-v1.md`](modem-contract-v1.md),
[`provisioning-contract-v1.md`](provisioning-contract-v1.md),
[`mbim-contract-v1.md`](mbim-contract-v1.md), the latest version-specific test
plan — currently [`testing-0.12.0.md`](testing-0.12.0.md) — and
[`roadmap.md`](roadmap.md) before changing runtime behavior. The README
describes released behavior; the changelog records shipped differences rather
than future intentions.

Coding assistants must also follow the root [`CLAUDE.md`](../CLAUDE.md). Its
0.10.0 review lessons record concrete failure patterns found during the first
modem-control implementation and are mandatory acceptance criteria for later
architectural releases.

## Current state and next release

Version 0.11.0 is released and hardware-validated. The suite discovers a modem,
provisions a disabled project-owned staging section, applies an APN through the
engine, verifies real Internet access, promotes autoconnect, and offers
connect/disconnect/reconnect, manual APN entry and the LuCI first-run card. All
of that works for ModemManager and native QMI targets only. It does not yet
mutate MBIM profiles or manage eSIM.

The next feature release is **0.12.0**, the complete native MBIM vertical slice:
inventory and ownership, provisioning, identity, profile capture/write/restore,
dynamic IPv4/IPv6 readiness, connection control, roaming policy and the LuCI
workflow.

**Its runtime work is implemented locally and passes `sh scripts/verify.sh`.**
What that does *not* mean is recorded honestly in
[`testing-0.12.0.md`](testing-0.12.0.md): the official SDK build and APK
inspection, the package-lifecycle matrix and the hardware gate are all open, and
the fixtures were written from the `umbim` source rather than from a modem. MBIM
therefore reports `implementation_state: alpha` and `validation_state:
synthetic`, and must not be relabelled until `docs/router-test-0.12.0.md`
exists. The hardware run switches the reference RM520N-GL into MBIM composition
and restores it afterwards, so it needs the recovery rehearsal described there.

Its accepted design is [`mbim-contract-v1.md`](mbim-contract-v1.md) and its plan
is [`testing-0.12.0.md`](testing-0.12.0.md). Three facts there are easy to miss
and expensive to get wrong: `umbim`'s exit status carries modem state rather
than failure, so a roaming modem exits non-zero from a healthy query; `-t`
suppresses the MBIM OPEN and `-n` suppresses the CLOSE, so the wrong combination
tears down the session netifd holds for a live bearer; and `umbim connect`
silently discards the username and password unless the auth value is exactly
`pap`, `chap` or `mschapv2`, so a normalized `pap-or-chap` must expand into
bounded attempts instead of being written verbatim.

Do not implement MBIM profile mutation as an isolated shortcut in the APN
engine's older code paths. The transport is new, but the boundary is not: the
adapter provides identity, the engine owns the five profile options and their
rollback, `apn-autoconfig-modem` owns the section, and netifd owns the bearer.

The agreed product and ownership rules are normative in `architecture.md`. In
particular, the final suite must work both when the modem is attached after the
software and when an internal or USB modem was already present before package
installation. Hotplug is never the only discovery mechanism.

## Released package and file map

- `apn-autoconfig`: GUI-independent POSIX-shell APN engine, narrow rpcd
  workers, boot worker and current internal ModemManager/QMI adapters.
- `apn-autoconfig-providers`: independently versioned generated TSV database.
- `luci-app-apn-autoconfig`: optional consumer of the public machine API.
- `apn-autoconfig-integration-huasifei-wh3000`: optional tested BTN_0/GPIO
  integration and its kernel dependency. It is not a generic button package.
- `files/usr/sbin/apn-autoconfig`: target discovery, backend dispatch, matching,
  state, connectivity verification, rollback and public CLI/JSON API.
- `files/usr/libexec/apn-autoconfig-qmi`: bounded read-only QMI/SIM transport.
- `files/usr/libexec/apn-autoconfig-query` and `-control`: narrow LuCI/rpcd
  allowlists. Do not grant LuCI the general-purpose CLI.
- `tests/run-tests.sh`: backend, state, failure, rollback, injection, reset and
  compatibility regressions.
- `scripts/verify.sh`: required local and CI gate.

## Target package map

The accepted names are `apn-autoconfig-modem`, `apn-autoconfig`,
`apn-autoconfig-providers`, `apn-autoconfig-proto-fibocom`,
`apn-autoconfig-esim`, optional `apn-autoconfig-lpac`, the existing
`luci-app-apn-autoconfig` and the existing Huasifei integration package.
Logical component names such as “modem control” must not become generic global
package, UCI, executable or ubus names.

`apn-autoconfig-modem` becomes the lower-level dependency. It owns read-only
inventory, stable identity, runtime capabilities, control-owner arbitration,
project-created netifd sections, connection/reset operations and the shared
operation coordinator. `apn-autoconfig` remains the APN policy consumer and
owns only declared APN/profile fields and rollback state. Netifd remains the
sole bearer owner.

## Binding and lifecycle invariants

1. Resolve exactly one stable modem and target before mutation. Zero,
   unavailable or ambiguous candidates fail closed.
2. Scan actual state at service start as well as hotplug. A modem attached
   before package installation must appear without physical reconnection.
3. Treat volatile `/dev` and netdev names as attributes. Rebind them only to a
   modem identity proven by physical topology and stronger identity evidence.
4. Keep discovery read-only. Provisioning is a later explicit transition that
   creates only a disabled, marked, project-owned staging section.
5. Keep netifd as bearer owner and one explicit control owner per modem. Never
   let direct protocol operations race ModemManager.
6. Capture and atomically persist complete owned baselines before the first
   write. Restore exact state after candidate, operation or removal failure.
7. Verify connectivity through the selected target's effective L3 route before
   keeping a changed profile or promoting autoconnect.
8. Keep credentials and identifiers out of logs and normal LuCI display.
   Root-owned baseline/cache state uses process-wide `umask 077`.
9. CLI, LuCI, boot, hotplug, provisioning, eSIM and physical buttons join one
   serialized operation model.
10. Capability, implementation state and validation evidence remain separate.
11. Removal restores or deletes only project-owned state and aborts safely when
    restoration cannot complete.

## Huasifei compatibility gate

The currently proven physical-button behavior must survive the architecture
migration. An enabled `BTN_0` release queues one bounded operation that
power-cycles the selected modem, waits for re-enumeration, refreshes its stable
binding, performs targeted APN `reconcile`, verifies connectivity and exposes
the result to LuCI. Press events remain ignored and repeated releases cannot
overlap.

Introduce the modem-control reset API first. Preserve
`apn-autoconfig modem-reset` and `action-start modem-reset` as compatibility
shims for at least one release. Do not move or remove the Huasifei package's
handler until manual reset, physical button, interruption, upgrade and package
removal tests pass against the new coordinator.

## Released public APN integration surface

Until a versioned replacement is implemented and documented, consumers use the
released commands through equivalently narrow privileged wrappers:

```text
apn-autoconfig targets-json
apn-autoconfig status-json [--target network:<section>]
apn-autoconfig detect-json [--target network:<section>]
apn-autoconfig action-start reconcile [--target network:<section>]
apn-autoconfig action-status
```

`targets-json` v2 remains authoritative for released target selection and
runtime capability. Status/detect v2 include `engine_api: v1`, target identity,
backend, effective data device and separate implementation/validation evidence.
New 0.10.0 APIs need an explicit schema and compatibility decision; do not
silently change these responses in place.

## 0.10.0 release state

The package skeleton, v1 inventory schema, QMI/MBIM/AT-only discovery,
ModemManager-first ownership, fail-closed ambiguity, common APN-to-modem lock
order, bounded GPIO reset, compatibility shim, service-start/hotplug scans,
LuCI inventory and synthetic tests are implemented. Reset remains disabled
until the maintainer pins the strong identity of the internal modem as
`apn-autoconfig-modem.main.reset_modem_id`; never infer a board-wide GPIO
binding from QMI protocol or USB VID:PID alone.

Official SDK build and APK inspection, clean/live/offline install behavior,
0.9.2 upgrade, removal simulation, the WH3000 manual/BTN_0 interruption and
reset-plus-reconcile hardware matrix, publication and the live signed-feed smoke
test are all complete and recorded in `testing-0.10.0.md`; the 0.10.1 lock
repair and the 0.11.0 provisioning release have since shipped on top of it. Any
defect found after publication requires a fixture regression and a follow-up
patch release rather than rewriting a release tag.

The 0.10.0 scope is architecture foundation and read-only inventory. It does
not automatically create network sections, add native MBIM profile writes,
ship the Fibocom protocol or expose eSIM actions. Record discoveries for later
milestones without folding those features into this release.

## Required workflow and release evidence

Inspect the worktree and preserve unrelated changes. After runtime, packaging,
LuCI or documentation edits run:

```sh
sh scripts/verify.sh
```

The two LuCI regression suites (`tests/test-luci-roaming-policy.js` and
`tests/test-luci-provisioning.js`, plus the `node --check` syntax check of the
view) need Node.js. On a machine without Node.js they are skipped, the run
prints a loud warning to stderr and the success line reports
`(LuCI suites SKIPPED: node not found)`. That result is not full coverage: CI
is the authoritative run for the LuCI suites there, and a green local gate
alone must never be cited as frontend evidence for a LuCI change. CI (`CI=true`)
and release builds (`EXPECTED_RELEASE_TAG` set) still fail hard when Node.js is
missing, so the suites always run before a release.

The release gate additionally requires the official OpenWrt 25.12 SDK build,
APK install/upgrade/removal simulation, the order-independent discovery matrix,
real hardware tests recorded in `testing-0.10.0.md`, rollback/recovery
artifacts, signed-feed installation and a final installed-package smoke test.
A green fixture suite is necessary but insufficient for a hardware claim.

Release tags are `v<suite-version>`. From 0.10.0, first-party code packages
participating in a suite release use the suite version; provider data remains
date-versioned and upstream-derived dependencies retain their upstream source
version. `PKG_RELEASE` denotes a packaging rebuild. The GitHub workflow must
reject inconsistent first-party versions and exact package-name collisions.
