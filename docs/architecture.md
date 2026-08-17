# Architecture and product principles

Status: accepted on 2026-08-13 for the post-0.9.2 release line.

This document defines the agreed direction of the first-party project from the
released 0.9.2 APN engine to the stable 1.0 mobile-connectivity suite. It is the
normative source for package boundaries, ownership and lifecycle principles.
[`roadmap.md`](roadmap.md) assigns those outcomes to releases;
[`development-handoff.md`](development-handoff.md) describes the current safe
implementation entry point. A future capability described here is not a claim
that the released packages implement it.

## Product goal

By 1.0, a user must be able to install the signed first-party package suite on
a clean supported OpenWrt system with a supported modem already present or
attach the modem later. The project must then:

1. discover the modem and assign it a stable project identity;
2. determine only capabilities that the installed runtime actually implements;
3. arbitrate ownership with netifd, ModemManager and any direct control path;
4. create and own the required OpenWrt network configuration safely;
5. select an automatic or user-supplied APN profile;
6. connect through netifd and verify real Internet connectivity;
7. expose modem, connection, APN and eSIM workflows in one coherent LuCI UI;
8. recover connectivity after SIM/eSIM changes, modem resets, re-enumeration
   and router restarts; and
9. remove or roll back only state owned by this project.

The final suite therefore must not require a pre-created, working cellular
connection. The released 0.9.2 `apn-autoconfig` package still does require an
already configured ModemManager or QMI netifd target; eliminating that
requirement is a planned, explicitly tested migration rather than an implied
current feature.

## System-wide invariants

These rules bind every component and release:

1. **Ambiguity fails closed.** Zero or multiple equally valid modems, control
   channels, targets or owners cause no persistent or network mutation.
2. **Observed state is authoritative.** Hotplug is an optimization, not the
   source of truth. Every event feeds an idempotent reconcile of the actual
   sysfs, ubus, netifd, UCI and backend state.
3. **Installation order is irrelevant.** The same result must be reachable
   when the modem is attached before package installation, after installation,
   present at boot or re-enumerated while the service is stopped.
4. **Netifd owns bearer lifecycle.** Project code may request a targeted
   connect, disconnect or reconnect; it must not leave a competing bearer
   active outside netifd.
5. **One active control owner per modem.** Direct QMI/MBIM/AT operations and
   ModemManager must not race. Ownership is explicit, observable and changed
   only through a bounded transition.
6. **Capability is not recognition.** A protocol name, USB ID or parser does
   not prove an installed operation or hardware support. Runtime capability,
   implementation maturity and validation evidence remain separate.
7. **Mutations are transactional and narrow.** Capture the complete owned
   baseline before a write, change only declared fields, verify the result and
   restore the exact previous state after failure or interruption.
8. **Every entry point joins one operation model.** CLI, LuCI, boot, hotplug,
   provisioning, eSIM and physical buttons use the same per-modem coordinator
   or documented lock ordering. They must neither overlap nor deadlock.
9. **Secrets and identifiers are protected.** Activation codes, APN
   credentials, ICCID, IMSI and EID do not appear in argv, normal logs or the
   default LuCI view. Persistent private state is root-only.
10. **Only project-owned state is removed.** Pre-existing UCI sections are not
    silently adopted, rewritten or deleted. Adoption and replacement require
    explicit identity evidence and user consent.
11. **Signed, reproducible distribution is mandatory.** Normal installation
    never requires `apk --allow-untrusted`. Source-built dependencies use
    pinned sources, preserved licences and recorded patch provenance.
12. **Hardware claims require hardware evidence.** Fixtures and SDK builds are
    required but cannot promote a capability to hardware-validated by
    themselves.
13. **Cleanup may not depend on the process that made the mess.** An exit trap
    covers the exits a shell controls, and SIGKILL is not one of them. Every
    temporary path carries its owning PID and must be removable by a successor
    that can prove the owner is gone.

## Scratch files, signals and the start-up sweep

Every scratch path the APN engine creates is `/tmp/apn-autoconfig.<pid>.<suffix>`
and every suffix it may use is listed once, in `TMP_SUFFIXES`, because two
different mechanisms have to agree on that list: the exit trap removes them by
exact name, and the start-up sweep recognizes a dead predecessor's files by the
same names. A suffix added to only one of the two leaks.

Three things can leave such a file behind, and they need different answers.

**A subshell assignment the parent never sees.** This was 0.13.2, in
`apn-autoconfig-modem`: the paths were assigned inside a function reached through
a command substitution, so the parent's trap removed an empty variable. Fixed by
assigning the paths once at start-up.

**An untrapped signal.** `trap … HUP INT TERM` left out PIPE, and death by an
untrapped signal never runs the exit trap. Every read-only command gathers all of
its data into scratch files before it writes the first byte of its answer, so a
reader that has already stopped kills the engine at the point where there is the
most to clean up. Reproduced on the reference router on 2026-08-17: `targets-json`
into a closed reader left exactly a `.targets` file, `status-json` left the
`.sim`/`.modem`/`.modems` set and `detect-json` added `.candidates` — the same
file sets that had accumulated there, which is also how each leftover set names
the command that produced it. The engine now traps PIPE and exits 141, the status
a caller already saw, so only the leak goes away. The same trap closes a worse
case than a scratch file: a mutation interrupted this way skipped its rollback,
its modem power-on and its lock release.

**SIGKILL, which no trap can cover.** rpcd's `file exec` — the transport under
every LuCI `fs.exec` call — kills the process it started when it exceeds rpcd's
configured timeout, 30 seconds by default in `/etc/config/rpcd`. Verified on the
router on 2026-08-17 with a probe script: after 30 seconds the exit trap had not
run, the scratch file survived and the probe's own child was still running,
orphaned. The engine's read path is also capable of reaching that budget on its
own — `resolve_sim_index` spends up to `APN_AUTOCONFIG_MMCLI_TIMEOUT_SECONDS`
(8s) on `mmcli -L` plus 8s per listed modem, then the SIM read and the status
refresh take 8s each,
so a wedged ModemManager costs 32 seconds with one modem present and 40 with two.
Bounding those callers below rpcd's budget is a separate change with its own
behavioral consequences; it is not what keeps `/tmp` bounded.

What keeps `/tmp` bounded is that the next run removes what a provably dead
predecessor left. `sweep_dead_scratch_files` globs only to find candidates: every
path it removes is one it rebuilt itself from a PID that is all digits and a
suffix from the list, it skips anything that is not a regular file, and it leaves
a live PID's files alone — they belong either to a concurrent engine or to an
unrelated process that was given that number. `/tmp` is shared, and a wildcard
removal there is what this project already forbids for its lock and state roots.
The sweep runs on every entry point rather than at service start, because LuCI is
the caller that never reaches one.

Two things are deliberately not covered. `apn-autoconfig-modem` has the identical
SIGPIPE exposure — confirmed on the router the same day, leaving `.inventory`,
`.inventory.display` and `.mm-indexes` — and is left for a patch that does not
collide with the AT framework's rewrite of that file. And the regression for this
can only run under a shell where an untrapped SIGPIPE is fatal: bash reports
status 141 and runs the exit trap anyway, so on a host whose `/bin/sh` is bash the
test would pass against the code it exists to reject. `tests/run-tests.sh` probes
for a suitable interpreter, and says so loudly when the host has none.

## Package namespace and boundaries

The package namespace remains the already published `apn-autoconfig-*` family.
The product title shown in LuCI may become **Mobile Connectivity**, but generic
global package names such as `modem-control`, `esim-control` and
`luci-app-mobile-connectivity` are deliberately avoided.

Exact names are audited against the supported OpenWrt package indexes and public
package trees when a package is **added or renamed**, and once before the 1.0
name freeze. Repeating the search for unchanged names every release produced the
same answer each time while suggesting the namespace was under continuous watch,
which it cannot be: a collision can appear the day after any check, and it
depends on other people's publishing rather than on this project's cadence.

Audits so far:

| Date | Scope | Result |
|---|---|---|
| 2026-08-13 | `apn-autoconfig-modem`, `-esim`, `-proto-fibocom`, `-lpac` | no exact collision |
| 2026-08-16 | all five published names | no exact collision; every `PKG_NAME` hit belongs to this repository, and the three official trees contain none |

### First-party packages

- `apn-autoconfig-modem`: modem inventory, stable hardware identity,
  capabilities, control-owner arbitration, operation coordination, connection
  state, provisioning and supported modem operations.
- `apn-autoconfig`: APN decision engine. It identifies the SIM and registration
  context needed for matching, chooses or accepts a profile, applies only
  declared profile fields, verifies connectivity and rolls back exactly.
- `apn-autoconfig-providers`: independently updated normalized provider data;
  it retains date-based data versions.
- `apn-autoconfig-proto-fibocom`: optional netifd protocol support for selected
  Fibocom/AT-managed devices not handled by a stock OpenWrt protocol.
- `apn-autoconfig-esim`: eSIM orchestration, profile lifecycle and the combined
  profile-switch, identity-refresh, APN-reconcile and connectivity workflow.
- `apn-autoconfig-lpac`: a private, upstream-tracking lpac build if upstream
  OpenWrt packages cannot provide the validated FM350 lifecycle. It must not
  replace, claim to provide or overwrite the official `lpac` package or binary.
- `luci-app-apn-autoconfig`: the common capability-driven UI. Keeping its
  published package name avoids a migration solely for branding.
- `apn-autoconfig-integration-huasifei-wh3000`: the existing optional,
  hardware-validated BTN_0/GPIO integration for the tested board.

All first-party code packages introduced by the architecture line use the
shared suite release version. The provider database keeps its data version. A
vendored or forked dependency keeps an upstream-derived source version plus a
downstream package revision. `PKG_RELEASE` is reserved for packaging rebuilds,
not feature milestones.

### Responsibility and ownership

`apn-autoconfig-modem` owns modem registry records, project-created network
sections, hardware binding, control-owner decisions and administrative
connection state. It publishes narrow machine APIs instead of granting LuCI or
other packages general shell access.

`apn-autoconfig` owns only APN/profile fields declared by the selected backend,
its exact baseline and per-SIM successful-profile cache. Roaming permission,
connect/disconnect, signal polling and reset belong to modem control even when
the APN UI displays related context.

A netifd protocol helper implements netifd's dial contract. It does not create
or own an independent bearer lifecycle. `apn-autoconfig-esim` owns eSIM
operations, not APN fields or network sections. The LuCI package consumes all
of these APIs and writes none of their private state directly.

## Discovery and reconcile lifecycle

All lifecycle signals converge on one idempotent state reconciliation:

- service start immediately after a live package installation;
- every router boot after the required system services become available;
- modem, USB, tty and network hotplug/re-enumeration;
- installation of an optional backend or board integration;
- completion of modem reset or eSIM profile switch; and
- an explicit CLI or LuCI rescan.

Package installation hooks enable and start the service on a live router but do
not inspect hardware or mutate UCI themselves. Offline image installation must
remain safe when ubus, netifd and hardware are absent. At runtime the service
performs a full read-only scan, so it never depends on replaying an event that
occurred before the package existed.

Volatile names such as `/dev/cdc-wdm0`, `ttyUSB2` and `wwan0` are attributes,
not identities. A stable modem record uses the strongest available combination
of physical USB topology, device serial and modem identity evidence. A section
may be rebound after proven re-enumeration, but a weak VID:PID-only match is not
proof of ownership.

Discovery and provisioning are separate phases. The initial architecture
release must discover an already present modem read-only. A later provisioning
release may create a disabled staging netifd section only after identity and
protocol are unambiguous, mark it as project-owned, invoke targeted APN
reconciliation, connect through netifd and promote the requested autoconnect
state only after connectivity succeeds. Failure removes or restores the
staging state without touching unrelated interfaces, mwan3 or Travelmate.

## Huasifei hardware integration compatibility

The verified WH3000 Pro behavior is a release invariant, not a temporary APN
feature. One enabled `BTN_0` **release** event must:

1. enter the common serialized operation coordinator;
2. target exactly the bound modem and netifd interface;
3. execute the guarded board-specific GPIO power cycle;
4. wait boundedly for USB/control/SIM re-enumeration;
5. refresh the stable modem binding;
6. run targeted APN `reconcile` after the modem returns;
7. verify Internet connectivity; and
8. publish the combined result to CLI and LuCI without changing unrelated
   network state.

Press events remain ignored, repeated releases cannot overlap, and interruption
while power is off must attempt to restore the configured powered-on state.
The integration remains opt-in and must not be generalized to other boards
without board-specific evidence.

During the architecture migration, the new modem-control reset API becomes the
owner of this workflow. The released `apn-autoconfig modem-reset` command stays
as a compatibility shim for at least one release. The old implementation and
package dependency may be retired only after upgrade, removal, manual reset and
physical-button tests prove the same reset-plus-reconcile outcome.

## Common LuCI experience

`luci-app-apn-autoconfig` evolves in place into one capability-driven shell:

- **Overview / Modem**: inventory, stable identity, ownership, protocol,
  provisioning status and actionable failures;
- **Connection**: registration, signal, access technology, connect,
  disconnect, reconnect and supported reset/power-cycle actions;
- **APN**: automatic and manual profiles, targeted reconcile, provider data
  and APN-specific diagnostics;
- **eSIM**: eUICC information, profiles, local QR decoding, bounded lifecycle
  actions, notifications and combined switch/reconcile status.

The first-run view appears for an unprovisioned supported modem. An optional
package may leave its tab visible with a clear installation/capability message,
but must never expose a control that the backend cannot execute. Arbitrary AT
terminals, raw device selection and undocumented reset cascades are not stable
GUI features.

## Managed lpac direction

The released lpac version and current OpenWrt package do not yet prove the full
FM350 workflow required by this project. If the eSIM milestone still needs
unmerged upstream changes, maintain a thin fork from a pinned active upstream
commit with one reviewable downstream commit per required fix. Track the
upstream work rather than creating an unrelated implementation.

The private package installs a namespaced executable below the project's
`libexec` directory and can coexist with official `lpac`. Activation and
confirmation secrets are accepted through a protected request channel, never
through command-line arguments, UCI or logs. TLS certificate verification is
never disabled. Hardware promotion requires information, list, download,
enable, disable, delete, notification, timeout/interruption and post-switch APN
recovery evidence.

## Required lifecycle matrix

Every stable release that changes inventory, ownership or provisioning must
test at least:

- modem attached before package installation;
- package installed before modem attachment;
- internal modem already present during boot;
- control driver becoming ready after the service starts;
- service stopped during hotplug and started later;
- modem reset and re-enumeration with changed volatile device names;
- one, zero and multiple eligible modems;
- coexistence with a pre-existing user-created network section;
- coexistence with ModemManager and direct protocol devices;
- package upgrade and removal with owned-state restoration; and
- Huasifei manual reset and physical BTN_0 reset followed by APN reconcile.

The same physical and logical modem state must converge to the same safe result
regardless of event order.
