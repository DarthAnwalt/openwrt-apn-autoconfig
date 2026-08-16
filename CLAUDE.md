# For Claude / coding assistants

Read [`docs/development-handoff.md`](docs/development-handoff.md) first — it is the
authoritative entry point for any coding assistant working on this repository.
It links to [`docs/backend-contract-v1.md`](docs/backend-contract-v1.md),
[`docs/testing-0.9.2.md`](docs/testing-0.9.2.md),
[`docs/testing-0.10.0.md`](docs/testing-0.10.0.md) and
[`docs/roadmap.md`](docs/roadmap.md). The README is the user-facing reference;
the changelog records shipped differences rather than future intentions.

If `.local-notes/next-release-architecture.md` exists in the maintainer's
workspace, read it after the public handoff. It contains uncommitted design
discussion and must not be copied into public documentation without an explicit
decision.

## Lessons from the 0.10.0 architecture review (mandatory)

The first 0.10.0 modem-control implementation had a sound package boundary but
was not release-safe without substantial follow-up. The review found incorrect
shell status propagation, incomplete signal cleanup, capability inference from
protocol alone, unsafe owner-discovery fallback, first-match device selection,
an inconsistent lock model, background-action races and incomplete package
lifecycle behavior. The rules below are acceptance criteria for future work,
not optional style preferences.

### POSIX shell errors and cleanup

- Never capture `$?` inside `if ! command; then`: `!` has already inverted the
  status. Use `status=0; command || status=$?`, then branch on `status`. Preserve
  backend/coordinator exit classes across every compatibility shim and worker.
- Model every mutation as a transaction. Arm cleanup state *before* `ifdown`,
  GPIO power-off, profile mutation or lock acquisition. On normal failure,
  `HUP`, `INT` and `TERM`, restore power-on first, then the selected interface
  and exact owned state, and finally release locks in reverse order.
- A backend's own timeout option is not proof that its process cannot hang.
  Every external `mmcli`, `uqmi`, `sms_tool`, network or device query needs an
  outer bound and an internal watchdog fallback for minimal images without a
  `timeout` executable. Cleanup must terminate and reap the active child.
- Keep scripts compatible with POSIX shell/BusyBox `ash`. Do not parse records
  containing empty tab-separated fields with a multi-variable shell `read`:
  tab is IFS whitespace and adjacent empty fields collapse. Use an explicit
  field extractor or a format with a parser that preserves empties.

### Identity, ownership and capabilities

- Enumeration order is never identity. Do not use the first `/dev`, sysfs,
  AT-port, data-device, ModemManager object or netifd match. Collect all
  candidates; exactly one proven match may proceed, while zero or multiple
  matches remain read-only and fail closed.
- Volatile device names are attributes, not stable IDs. Strong binding requires
  physical USB topology plus USB serial or validated IMEI evidence. Equal weak
  VID:PID devices are ambiguous even if their temporary bus paths differ.
- Protocol support does not imply a physical or write capability. In
  particular, `protocol=qmi` must never advertise the board GPIO reset. Reset
  requires the supported board marker, writable validated GPIO path and an
  explicit exact `reset_modem_id` using strong evidence. Leave it disabled by
  default.
- Discover the current control owner before opening a control channel. A modem
  claimed by ModemManager must not receive a direct `uqmi` probe. Failed,
  timed-out or unparseable owner discovery is uncertainty, not permission to
  fall back to direct access; retain weak read-only inventory for that scan.
- Keep runtime capability, implementation maturity and validation evidence as
  separate fields. Never label a path stable or hardware-validated because a
  synthetic fixture passes.

### Locks and operations

- Document one global lock order before implementing a composite operation.
  The current reset/reconcile order is the global APN operation lock followed
  by the selected per-modem lock. Release in reverse order. Never acquire the
  same pair in the opposite order from CLI, LuCI, boot, hotplug or button paths.
- A child may borrow a caller's global lock only when the caller passes its PID,
  the lock records that exact PID and the process is still alive. The mere
  presence of an environment variable or lock directory is not ownership.
- Device-specific read transactions must share the same lock namespace as the
  existing adapter. New inventory code must not overlap an APN adapter's QMI or
  AT identity transaction.
- Background launch needs an atomic start lock that survives the parent/worker
  handoff. State must contain a schema version, operation ID, modem ID, action,
  PID and terminal result. Detect operations started outside the job API, reap
  stale owners, and ensure two simultaneous starts accept exactly one worker.
- Revalidate presence, identity, capability and owner after acquiring all
  operation locks. Pre-lock validation alone has a time-of-check/time-of-use
  race.

### Verified WH3000 button compatibility

- Preserve the hardware-validated hotplug contract exactly: the WH3000
  integration accepts only `BUTTON=BTN_0` with `ACTION=released`, remains
  disabled by default for new installs and ignores press events. Do not infer a
  replacement event name from device-tree labels when the real hotplug event
  has already been validated on this board.
- A release must call `action-start modem-reset` and return promptly. Never
  fork a direct synchronous reset from hotplug and never bypass the common
  operation lock or coordinator.
- Parse the versioned launch response. `accepted:true` means a worker was
  accepted; `accepted:false,busy:true` means a repeated release was safely
  coalesced and must be logged as an ignored duplicate, not as a newly started
  reset. A non-busy rejection, malformed response or nonzero command status is
  a hotplug failure.
- Regression coverage must include disabled mode, ignored press, accepted
  release, busy duplicate, malformed/rejected launch and the hardware invariant
  that two releases during one running operation produce two release events but
  only one power-cycle and one terminal result.

### Compatibility and package lifecycle

- A compatibility fallback is permitted only when the new optional package is
  actually absent. Once the coordinator is installed, failure to resolve an
  unambiguous safe binding must fail closed; silently falling back bypasses the
  new ownership boundary.
- Preserve public command, JSON and exit-code behavior unless a versioned
  migration is explicitly documented and tested. A source grep for delegation
  hooks is not compatibility evidence: run mocked success, failure and
  nonzero-status propagation through the real shim.
- Test all installation orders: hardware before live install, package before
  attachment, boot with delayed dependencies, service restart, and offline
  image-root install. Live `postinst` may enable/start discovery; an
  `IPKG_INSTROOT` install must not access services or hardware.
- Removal must stop new work without erasing locks owned by a live operation.
  Never use a broad wildcard or recursive deletion for lock roots. Resolve
  exact project-owned paths and delete only regular state or provably stale
  locks. Preserve config/baseline restoration semantics across upgrades.
- Inspect the actual APK produced by the official supported SDK rather than
  inferring package contents from the source tree. This is a per-release
  requirement: it is what catches a file that reached a published package
  without being declared.
- Audit exact package names against official OpenWrt indexes and public package
  trees **when a package is added or renamed**, and once before the 1.0 name
  freeze. Not every release: an unchanged name gives the same answer every
  time, the risk is driven by other people's publishing rather than by our
  cadence, and a collision can appear the day after any check. Record the date
  and result of each audit in `docs/architecture.md` so the last answer is
  attributable.

### Tests required for architectural work

For each mutation or arbitration feature, add behavioral tests for success and
failure plus the relevant hostile cases:

- zero/one/multiple candidates and duplicate ownership claims;
- dependency absent, output malformed, query timeout and owner discovery
  uncertain;
- real `TERM` during the destructive window, proving power/interface/state and
  locks are restored;
- two simultaneous launches, stale worker/lock recovery and an externally
  started synchronous operation;
- install, offline install, upgrade and removal while hardware is already
  present; and
- compatibility-shim success and exact nonzero status propagation.

Prefer executable fixture assertions over grepping for implementation text.
Every defect found by review, SDK, CI or hardware validation must receive a
regression test before the fix is considered complete.

## Before proposing any change as done

Runtime, packaging, LuCI, or documentation changes must pass:

```sh
sh scripts/verify.sh
```

A green fixture suite is necessary but not sufficient for a hardware-support
claim — see the latest version-specific testing document for the evidence
ladder (synthetic → hardware) before marking any backend
`stable`/`hardware_validated: true`.

Before reporting an architectural release task complete, distinguish clearly
between: implemented locally, synthetic tests passed, official SDK/APK gate
passed, package lifecycle tested, and physical hardware validated. List every
remaining gate explicitly; do not turn an unrun gate into an assumption.

## Non-negotiable safety invariants

See `docs/development-handoff.md` for the full list. In short: resolve one
unambiguous target before any mutation; treat `detect`/`status`/`targets-json`
as strictly read-only; capture and validate the full baseline before the
first write; touch only backend-owned UCI options and only the selected
netifd interface; verify real connectivity before keeping a candidate;
restore the exact prior profile on any failure; never log credentials or
SIM identifiers.

## Commits

This project uses the Developer Certificate of Origin. Sign off every
commit:

```sh
git commit -s
```

## Secrets

Never read, print, copy, or propose changes to `APK_SIGNING_KEY_BASE64` or
any other repository/Actions secret. The private APK signing key must never
enter the source tree, build artifacts, or a commit.

## Hardware access

This repository targets a physical OpenWrt router (Huasifei WH3000 Pro +
Quectel RM520N-GL) on the maintainer's local network. Do not assume that a
session can reach it: verify access before planning a live gate. Hardware
claims require captured router evidence under the current version-specific
test plan and must be recorded before a release is called stable.
