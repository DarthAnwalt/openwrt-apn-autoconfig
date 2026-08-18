# Development handoff

This is the shortest safe entry point for the next implementation task. Read it
with [`architecture.md`](architecture.md), [`backend-contract-v1.md`](backend-contract-v1.md),
[`modem-contract-v1.md`](modem-contract-v1.md),
[`provisioning-contract-v1.md`](provisioning-contract-v1.md),
[`mbim-contract-v1.md`](mbim-contract-v1.md),
[`atdial-contract-v1.md`](atdial-contract-v1.md), the latest version-specific
test plan — currently [`testing-0.15.0.md`](testing-0.15.0.md) — and
[`roadmap.md`](roadmap.md) before changing runtime behavior. The README
describes released behavior; the changelog records shipped differences rather
than future intentions.

Coding assistants must also follow the root [`CLAUDE.md`](../CLAUDE.md). Its
0.10.0 review lessons record concrete failure patterns found during the first
modem-control implementation and are mandatory acceptance criteria for later
architectural releases.

## Current state and next release

Version 0.14.1 is released. The suite discovers a modem, provisions it, selects
and applies an APN, verifies real Internet access, controls the connection and
manages roaming policy — over ModemManager, native QMI and native MBIM — and
identifies a modem that answers only 3GPP AT, which 0.14.0 added as the
precondition for what follows.

The next release is **0.15.0, the AT-dialed connection path**. Its plan is
[`testing-0.15.0.md`](testing-0.15.0.md) and its normative behaviour is
[`atdial-contract-v1.md`](atdial-contract-v1.md).

Five points there are easy to get wrong.

**The protocol handler must create the network device, not wait for one.** The
measured FM350-GL presents an RNDIS interface pair with **no driver bound** on
this image, so it has no network device at all. A handler that resolves a netdev
before loading `rndis_host` finds nothing, forever.

**The AT port is asked for, never probed for.** `apn-autoconfig-modem` already
resolves ports by role, caches negative verdicts and refuses under ModemManager.
A second resolver in the protocol package would race the first for the same tty,
which is the exact failure 0.14.0 was built to prevent.

**The AT port lock is mandatory, and this is where it earns its cost.** The
address published on the interface comes from a reply to `AT+CGPADDR`. A
component that waits for the lock, fails, and proceeds anyway configures the
interface with someone else's answer — up, wrong, and silent about it.

**Ownership is taken with ModemManager's own mechanism, or not at all.**
`mmcli --inhibit-device` names one stable device and is held by a supervised
process for exactly as long as the provisioning that asked for it. ModemManager
is never restarted: it would drop every session it manages, including the
working modem next to the one being configured.

**Registration with netifd is not the same as installation.** netifd reads
`/lib/netifd/proto/*.sh` only at start, while it spawns the handler from disk for
every setup — so changed dial logic arrives on the next bring-up, and a first
install does need a restart. The option schema follows registration, not the
logic: a new interface option is not accepted until netifd has been restarted,
so one must be introduced with a default that behaves exactly as its absence
did. That restart belongs to an explicit provisioning a user is waiting for,
never to a package script.

The hardware gate decides this release, and its evidence is deliberately uneven:
the FM350-GL path is validated, and the Intel XMM tail for the L850/L860 is
`alpha`/`synthetic` because no such device has been driven here. Fixtures cannot
reproduce a link that carries nothing because ARP was left enabled.

## Released package and file map

- `apn-autoconfig`: GUI-independent POSIX-shell APN engine, narrow rpcd
  workers, boot worker and current internal ModemManager/QMI adapters.
- `apn-autoconfig-providers`: independently versioned generated TSV database.
- `luci-app-apn-autoconfig`: optional consumer of the public machine API.
- `apn-autoconfig-integration-huasifei-wh3000`: optional tested BTN_0/GPIO
  integration and its kernel dependency. It is not a generic button package.
- `apn-autoconfig-proto-atdial`: optional netifd protocol `apn_atdial` for
  AT-dialed RNDIS/ECM/NCM modems with no control channel. Installing it does not
  register it with netifd; see the provisioning contract.
- `files/usr/sbin/apn-autoconfig`: target discovery, backend dispatch, matching,
  state, connectivity verification, rollback and public CLI/JSON API.
- `files/usr/libexec/apn-autoconfig-qmi`: bounded read-only QMI/SIM transport.
- `files/usr/libexec/apn-autoconfig-query` and `-control`: narrow LuCI/rpcd
  allowlists. Do not grant LuCI the general-purpose CLI.
- `apn-autoconfig-proto-atdial/files/lib/netifd/proto/apn_atdial.sh`: the dial
  handler. It sends only literal AT strings and never accepts a command from
  UCI, the environment or a caller.
- `apn-autoconfig-proto-atdial/files/usr/libexec/apn-autoconfig-atdial-at`:
  bounded AT executor and client of the shared AT port lock namespace.
- `tests/run-tests.sh`: backend, state, failure, rollback, injection, reset and
  compatibility regressions.
- `tests/run-tests-atdial.sh`: dial sequence, error classes, lock refusal,
  interruption and quirk regressions for the protocol package.
- `scripts/verify.sh`: required local and CI gate.

## Target package map

The accepted names are `apn-autoconfig-modem`, `apn-autoconfig`,
`apn-autoconfig-providers`, `apn-autoconfig-proto-atdial`,
`apn-autoconfig-esim`, optional `apn-autoconfig-lpac`, the existing
`luci-app-apn-autoconfig` and the existing Huasifei integration package.
Logical component names such as “modem control” must not become generic global
package, UCI, executable or ubus names.

The same rule reaches further than package names. **netifd protocol names are a
global namespace shared with every other package on the router**, and a
collision there overwrites a file rather than refusing an install:
`luci-app-5gmodem` already ships `/lib/netifd/proto/fibocom.sh`, which is why
the protocol added in 0.15.0 is `apn_atdial` and the package that carries it is
`apn-autoconfig-proto-atdial`. Protocol names must also be valid shell
identifiers, because netifd builds handler function names from them — a hyphen
produces a function definition `dash` refuses to parse.

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
