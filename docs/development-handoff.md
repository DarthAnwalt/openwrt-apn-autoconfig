# Development handoff

This is the shortest safe entry point for the next implementation task. Read it
with [`architecture.md`](architecture.md), [`backend-contract-v1.md`](backend-contract-v1.md),
[`modem-contract-v1.md`](modem-contract-v1.md),
[`provisioning-contract-v1.md`](provisioning-contract-v1.md),
[`mbim-contract-v1.md`](mbim-contract-v1.md), the latest version-specific test
plan — currently [`testing-0.14.0.md`](testing-0.14.0.md) — and
[`roadmap.md`](roadmap.md) before changing runtime behavior. The README
describes released behavior; the changelog records shipped differences rather
than future intentions.

Coding assistants must also follow the root [`CLAUDE.md`](../CLAUDE.md). Its
0.10.0 review lessons record concrete failure patterns found during the first
modem-control implementation and are mandatory acceptance criteria for later
architectural releases.

## Current state and next release

Version 0.13.2 is released. The suite discovers a modem, provisions it, selects
and applies an APN, verifies real Internet access, controls the connection and
manages roaming policy — over ModemManager, native QMI and native MBIM — and
presents all of it through the reorganized frontend that 0.13.0 delivered.

The next release is **0.14.0, the AT identity backend and bounded AT
transport**. Its plan is [`testing-0.14.0.md`](testing-0.14.0.md), and the
contract deltas are already written into
[`modem-contract-v1.md`](modem-contract-v1.md) and
[`backend-contract-v1.md`](backend-contract-v1.md).

Four points there are easy to get wrong.

It is a **dependency, not a feature wanted for its own sake.** An FM350 in RNDIS
composition exposes no `cdc-wdm` node, so neither the QMI nor the MBIM adapter
can read its SIM. Without AT identity, 0.15.0 could dial that modem and still
have no way to choose an APN for it.

**The command vocabulary is the easy part.** The 3GPP core reads are uniform
across vendors, and the bootstrap that learns which modem this is uses no vendor
knowledge at all — `AT+CGMI`/`AT+CGMM` are the *output* of the probe, not a
precondition for it. The work is port ownership: resolving a port by observed
role, bounding every call on images without an external `timeout`, and holding a
mandatory lock rather than an opportunistic one.

**One earlier rule is reversed.** Multiple AT ports on one proven USB device
were terminal ambiguity, which made an ordinary seven-port modem permanently
unusable rather than safe. Ports on one device are redundancy; ambiguity between
devices still fails closed.

**Reset becomes one capability with three implementations** chosen by control
owner. Under ModemManager the answer is to ask ModemManager to reset, not to
refuse: refusing would encode one deployment's shape into the contract and leave
a ModemManager user with no reset at all on a board without GPIO.

The hardware gate is where this release is decided, and it needs two modems
attached at once. Fixtures cannot reproduce a port that accepts a write and
never answers, a port that answers `OK` while being a debug channel, a reset
that removes its own port mid-command, or a re-enumeration that renumbers a
neighbouring modem's tty nodes — and those are the failures that matter.

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

### The hardware gate pins packages, and the smoke test must undo it

`apk add ./package.apk` records an exact-version constraint in `/etc/apk/world`,
because installing a named file is a statement about which version the
administrator wants. Every hardware gate installs checksum-verified local
artifacts exactly that way, so **the gate itself leaves the router unable to
upgrade those packages.** A later `apk upgrade` then changes nothing and still
prints `OK: … in N packages`, because the recorded constraint is satisfied.

This is not a defect in the packages. Their dependencies are unversioned, and
mixed suite versions install and run against each other. It is a property of the
test procedure, and it makes a signed-feed smoke capable of reporting success
while installing nothing at all.

Two rules follow, and both are part of the smoke test rather than optional
hygiene:

1. Before installing from the feed, clear the constraints the local install
   wrote, by re-adding the packages by bare name:

   ```sh
   apk add apn-autoconfig apn-autoconfig-modem apn-autoconfig-providers \
       luci-app-apn-autoconfig apn-autoconfig-integration-huasifei-wh3000
   tr ' ' '\n' < /etc/apk/world | grep apn-autoconfig | grep -v '^[a-z0-9-]*$'
   ```

   That second line must print nothing: every entry has to be a bare name.
   Checking for `=` specifically is not enough, and this is a correction rather
   than a refinement. Observed on the reference router on 2026-08-17 and again
   on 2026-08-18, the recorded constraints take the form
   `apn-autoconfig><Q1ufVq…=` — a checksum constraint written by the installed
   apk-tools, with no `=` in the operator at all. The old check reported clean
   against a router that was still fully pinned, which is precisely the false
   pass this step exists to prevent.

2. Confirm what actually landed instead of trusting the exit status:

   ```sh
   apk list -I | grep apn-autoconfig | sort
   ```

Leaving a pinned entry behind also degrades the router afterwards: the
maintainer's own device silently stops receiving suite upgrades. Restore it to
bare names before the session ends.

Release tags are `v<suite-version>`. From 0.10.0, first-party code packages
participating in a suite release use the suite version; provider data remains
date-versioned and upstream-derived dependencies retain their upstream source
version. `PKG_RELEASE` denotes a packaging rebuild. The GitHub workflow must
reject inconsistent first-party versions and exact package-name collisions.
