# Changelog

## apn-autoconfig 0.12.0 / apn-autoconfig-modem 0.12.0 / apn-autoconfig-providers 2026.08.10 / luci-app-apn-autoconfig 0.12.0 (unreleased)

Native MBIM support, from discovering the modem to verifying its connection.
Until now a CDC-MBIM modem was recognised and then refused everywhere after
that: provisioning called it an unsupported protocol and the APN engine had no
backend for it.

- Added `/usr/libexec/apn-autoconfig-mbim`, a strictly read-only identity
  adapter over `umbim`'s `subscriber`, `home` and `registration` queries. It
  never issues a command that could change a profile, the SIM, the radio or a
  bearer. `umbim` is not a new package dependency: a missing one makes the MBIM
  capabilities false without hiding the configured target.
- The adapter decides from netifd's own state whether to open a control
  session. `mbim.sh` holds one open for the life of a bearer, so an identity
  query borrows it with a transaction id from a separate range and never closes
  it. An interface up without a recorded session, a pending interface, two
  sections claiming one device and an unresolvable active section are all
  retryable and issue no command at all. A session id left behind by a killed
  teardown is treated as stale rather than blocking identity forever.
- `umbim` exits with the observed modem state rather than a failure for several
  perfectly valid answers, so validated output decides: a modem registered in
  roaming or on a partner network produces normal identity, while a truncated
  or unparseable message is a hard failure and a SIM that is not ready is
  retryable with its state named in the log.
- The APN engine owns the same five netifd options as for QMI, but writes MBIM's
  `pdptype` vocabulary — `ipv4`, not qmi.sh's canonical `ip`, which `umbim` would
  read as "let the modem decide".
- A normalized `pap-or-chap` profile is expanded into bounded `chap`-then-`pap`
  attempts, because `umbim connect` accepts one protocol and **silently discards
  the username and password** for any other value. The protocol that carried the
  session is what gets cached and reconciled, and the provider-label refresh
  still matches the `pap-or-chap` database row it came from.
- A rejected dual-stack bearer gets the same single bounded IPv4 retry QMI has,
  now expressed in a shared per-backend attempt planner. A pre-existing `ipv6=0`
  is read as an external constraint: an IPv6-only candidate is skipped rather
  than attempted, a dual-stack one becomes an IPv4 attempt, and the option is
  never rewritten.
- Connectivity verification waits for an addressed `<interface>_4` or
  `<interface>_6` dynamic interface, which is where `mbim.sh` puts the address.
- MBIM roaming policy is readable and writable through its real option pair:
  `allow` sets `allow_roaming` and `allow_partner`, `block` clears both,
  `default` deletes both. OpenWrt's absent MBIM default **blocks** roaming,
  unlike ModemManager's, and LuCI now says so. A mixed pair is reported as a
  custom configuration and is never normalized by opening the page or running an
  operation.
- Capability is reported as separate `roaming_policy_read` and
  `roaming_policy_write` booleans, additively; the existing `roaming_policy`
  string keeps its meaning, and LuCI drives the control from the capability
  instead of a backend name. QMI still reports it unsupported.
- `apn-autoconfig-modem` provisions an MBIM modem as a `proto=mbim` staging
  section on its own control device, with the same ownership markers,
  `disabled=1`, `auto=0` and absent `apn` as a QMI one. Inventory and
  provisioning still never open an MBIM control channel, which the tests assert
  from recorded invocations.

MBIM ships as `implementation_state: alpha` and `validation_state: synthetic`.
Its fixtures were written from the exact `umbim` revision OpenWrt 25.12.5 ships
(`2025.10.04~2939b7d0`) rather than from hardware, and the live gate in
`docs/testing-0.12.0.md` has not been run. See `docs/mbim-contract-v1.md`.

## apn-autoconfig 0.11.0 / apn-autoconfig-modem 0.11.0 / apn-autoconfig-providers 2026.08.10 / luci-app-apn-autoconfig 0.11.0 (2026-08-15)

Safe first-run provisioning for a modem that has no network configuration yet.
Until now the suite could only manage a cellular interface someone had already
created by hand.

- Added `apn-autoconfig-modem provision`. It creates one disabled,
  project-owned staging section for an unambiguous unconfigured modem, hands
  APN selection to the APN engine over a borrowed operation lock, and enables
  automatic connection only after the engine verified real Internet access.
  The staging section carries no `apn` option and `disabled=1`, so netifd
  cannot dial a vendor default before a profile is chosen. Rollback is armed
  before the first write and unwinds a failure at any later step, a signal, and
  a reconciliation that fails or reports retryable.
- Added `deprovision`, which is the exact inverse and refuses any section that
  does not carry the ownership marker, and `connect`, `disconnect` and
  `reconnect` for sections this package owns. netifd remains the bearer owner.
- An interface you created yourself is never adopted, rewritten or removed. A
  modem already bound to one is refused with `already_configured`.
- A disabled project-owned section is excluded from the APN engine's automatic
  target selection, so preparing a second modem cannot break APN operations on
  one that already works.
- Added `apn-autoconfig apply-manual` for an APN the database does not cover,
  running through the same baseline, verification and rollback path as a
  database candidate. A password is accepted only on standard input.
- Added `apn-autoconfig forget-target`, which drops one target's engine state
  and refuses while its section still exists. `reset --target` cannot be used
  for this, because with no baseline it clears a cache shared by every target.
- LuCI gained a modem setup card and manual APN entry. Controls appear only for
  what is actually possible; anything refused is explained instead. The manual
  password travels in the request environment, never as a command argument,
  because `/proc/<pid>/cmdline` is readable by any local process while
  `/proc/<pid>/environ` is not.
- Package removal now clears provisioning state as well as the inventory
  registry. Sections this package created are deliberately left in place and
  keep working, because netifd owns the bearer.

## apn-autoconfig 0.10.1 / apn-autoconfig-modem 0.10.1 / apn-autoconfig-providers 2026.08.10 / luci-app-apn-autoconfig 0.10.0 (2026-08-14)

Mainly a defect-fix release for the operation-lock protocol. It also carries two
additive changes that are the first runtime step of the 0.11.0 provisioning
work; they are listed separately below because this release is otherwise
behaviour-preserving.

- Fixed the operation-lock protocol. A lock was created in two steps — `mkdir`,
  then write the owner PID — and any process arriving between them read an
  empty PID, concluded the owner had crashed, deleted the live lock and
  continued. A lock is now a regular file whose first line is the owner PID,
  published atomically with `ln`, so the name and its owner appear together and
  that window cannot exist. A dead owner's lock is reclaimed only under an
  `ln`-guarded reclaim mutex that re-reads the owner inside the guarded
  section. `apn-autoconfig`, `apn-autoconfig-qmi` and `apn-autoconfig-modem`
  share one implementation because the global APN lock and the per-device QMI
  identity lock are cross-package namespaces.
- Two concurrent `action-start` calls could therefore both be accepted, which
  contradicted the 0.10.0 note about atomic launch serialization. Exactly one
  worker is now accepted, and the repeated-launch invariant is asserted over
  several rounds instead of a single attempt.
- `action-status` no longer reports an accepted operation as a dead worker
  during the launcher-to-worker handoff. The launcher hands its start lock to
  the worker, and the status path treats another process's live start lock as
  proof that the handoff is in flight. On the WH3000 this window made a
  duplicate `BTN_0` release look like a rejected launch — a hotplug failure —
  instead of a coalesced duplicate.
- Inventory can no longer take over the QMI identity lock from the APN engine's
  in-flight transaction on the same control device. The identity adapter also
  no longer spins forever on a lock path that is not a directory.
- `modem_wait_seconds` is a wall-clock bound again. The re-enumeration wait
  counted poll intervals and ignored the time each inventory scan spent in its
  own bounded ModemManager calls, so the configured and LuCI-labelled maximum
  could be exceeded several times over with the interface still down.
- A hotplug debounce window whose worker was killed no longer disables every
  later USB rescan for the rest of the uptime; the marker records an owner and
  is reclaimed like any other lock.
- Contention on the shared APN lock is reported as the retryable exit class
  instead of a generic failure, so a background worker records `retryable`
  rather than `failed`.
- Package removal understands both lock representations and still refuses to
  delete a lock owned by a live operation.

Additive changes from the 0.11.0 provisioning work, included here because they
were built and hardware-validated as part of this release:

- Added `apn-autoconfig-modem provision-plan --modem <id>`, a strictly read-only
  query that reports whether a modem could be provisioned and, when it cannot,
  a stable machine-readable reason. It writes no configuration, creates no state
  and opens no control channel. Nothing else in the provisioning workflow is
  implemented yet; see `docs/provisioning-contract-v1.md`.
- `apn-autoconfig` now excludes **disabled sections marked as owned by
  `apn-autoconfig-modem`** from automatic target selection. This is a behaviour
  change to `auto`, and it exists so that a future staging section cannot make
  `auto` ambiguous and break APN operations on a modem that already works. An
  explicit `--target` still selects such a section, and sections that are not
  marked project-owned are entirely unaffected — as is every existing
  configuration, since no released version creates these markers.

Upgrade note: 0.10.0 still uses the old two-step protocol, so upgrade the suite
packages together rather than mixing 0.10.0 and 0.10.1 binaries against a
shared lock. Locks left behind by 0.10.0 are honored while their owner lives
and reclaimed once it exits.

## apn-autoconfig 0.10.0 / apn-autoconfig-modem 0.10.0 / apn-autoconfig-providers 2026.08.10 / luci-app-apn-autoconfig 0.10.0 (2026-08-14)

- Added the `apn-autoconfig-modem` package: read-only modem inventory with
  stable identity independent of volatile `/dev` names (USB serial > IMEI >
  weak VID:PID evidence), explicit
  none/netifd-direct/modemmanager/conflicting control-owner states and a
  per-modem operation coordinator. See `docs/modem-contract-v1.md`.
- Hardened the foundation before hardware validation: inventory now classifies
  QMI, MBIM and AT-only devices without issuing direct QMI identity requests
  against ModemManager-owned or ownership-uncertain hardware; direct QMI
  identity remains locally bounded without an external `timeout`; duplicate
  weak identities, control devices and netifd bindings fail closed instead of
  selecting the first item.
- Normalize the physical USB device-root paths emitted by ModemManager and
  stored in netifd `device`/`devpath` on WH3000 so their observations merge with
  the correlated QMI control and data devices instead of producing separate
  incomplete records.
- Treat multiple AT ports on a proven QMI/MBIM modem as an unavailable optional
  AT attribute rather than a conflict for the whole modem; AT-only devices
  still fail closed until a port can be identified by role.
- Reset capability now requires an explicit strong `reset_modem_id` binding to
  the internal modem controlled by the WH3000 GPIO. Signal/error cleanup always
  restores power and the selected interface, and APN/modem operations share the
  documented global-to-per-modem lock order.
- Reset completion now requires the same stable modem identity to return under
  its original control owner before netifd is restarted. The compatibility
  path then waits boundedly for ModemManager's primary SIM and interface before
  APN reconciliation, preventing a raw USB re-enumeration from being mistaken
  for an operational modem.
- All core ModemManager reads now have an eight-second per-call bound with a
  portable watchdog fallback when `timeout` is unavailable. Signal cleanup
  also terminates both the bounded child and its watchdog, so the documented
  reset readiness window cannot silently turn into an unbounded D-Bus wait.
- Background modem actions now use atomic launch serialization, versioned v2
  state with operation IDs and terminal blocked/retryable results. Live package
  installation enables the service and performs a delayed full scan, while
  offline image installation remains inert.
- The verified WH3000 `BTN_0` release handler now parses the job launch result:
  accepted work, a safely coalesced busy duplicate and a real rejection receive
  distinct truthful logs. Press events remain inert and repeated releases still
  cannot overlap modem resets.
- Package removal preserves locks owned by live operations and no longer uses
  a broad wildcard to delete modem-control runtime paths.
- `apn-autoconfig modem-reset` (and `action-start modem-reset`) delegate the
  guarded power-cycle and re-enumeration wait to `apn-autoconfig-modem` when
  it is installed and can unambiguously resolve the target's explicitly
  reset-capable modem; the released inline path is used only when the new
  package is absent. An installed coordinator that cannot prove a safe binding
  fails closed instead of silently bypassing the new ownership boundary.
  Coupling is soft this release: no new package dependency.
- Added a read-only "Modem inventory" card to the LuCI view, fed by the new
  package's narrow rpcd query method; it shows an informational message
  instead of a broken control when the optional package is not installed.
- This is an architecture-foundation release: it does not add automatic
  network provisioning, native MBIM profile mutation or eSIM support. See
  `docs/architecture.md`, `docs/roadmap.md` and `docs/testing-0.10.0.md`.
- Passed the Huasifei WH3000 hardware gate: manual and physical-button
  reset-plus-reconcile, interruption recovery, repeated-release coalescing and
  LuCI observation all restored the same ModemManager-owned modem, `wwan` and
  verified connectivity without overlapping power cycles.

## apn-autoconfig 0.9.2 / apn-autoconfig-providers 2026.08.10 / luci-app-apn-autoconfig 0.6.0 (2026-08-13)

- Made service shutdown safe during QMI reconciliation: boot and background
  workers now forward termination to the active engine, the QMI teardown pause
  is interruptible, and procd allows enough time for the bounded request plus
  exact profile rollback and interface recovery.
- Added real `SIGTERM` regression coverage that interrupts a QMI apply during
  its teardown quiet period and verifies restoration of every owned UCI field
  plus the final interface `ifup`.
- Added worker-level signal-forwarding tests and enforce root-only `0600`
  action, baseline, active-profile and credential-cache state.
- Rejected carriage returns as well as tabs and newlines in backend/state
  values, preventing terminal output from being visually forged by modem data.
- Canonicalized QMI sysfs devpaths before enumeration and reject symlinks that
  resolve outside the configured sysfs devices tree.
- Bound legacy v1/v2 baselines to the selected interface before any restore
  write, matching the existing v3 target check.
- Consolidated the shared ModemManager/QMI profile capture, mutation and
  rollback plumbing while retaining backend-owned authentication and IP-family
  option mappings.
- Wait for the real QMI IPv4/IPv6 data interface after a board modem reset,
  instead of treating the parent netifd interface as ready while `qmi.sh` is
  still establishing its bearer. This prevents the post-reset identity query
  from racing netifd on the RM520N-GL.
- Clarified that QMI roaming state is observable but QMI roaming-policy control
  remains unavailable until a portable netifd mapping is hardware-validated.

## apn-autoconfig 0.9.1 / apn-autoconfig-providers 2026.07.18 / luci-app-apn-autoconfig 0.6.0 (2026-07-22)

- Added a native QMI backend: identity through `uqmi`/same-device AT fallback,
  backend-specific profile capture, UCI mapping, netifd apply, reconciliation,
  automatic failure rollback and persistent reset.
- Mapped normalized authentication to QMI `auth` (`pap-or-chap` becomes
  `both`) and IP family to `pdptype` (`ipv4` becomes canonical `ip`).
- Added one bounded `ipv4v6` to IPv4 retry when OpenWrt's QMI handler rejects
  the dual-stack bearer, and cache the effective working family explicitly.
- Added `sms-tool` as the small common core dependency and a strictly
  allow-listed `AT+CCID`/`AT+QCCID`/`AT+CIMI` fallback for QMI devices whose
  firmware rejects native QMI ICCID/IMSI operations.
- Restricted automatic AT probing to validated `ttyUSB`/`ttyACM` ports below
  the same physical USB device as the selected QMI control channel.
- Added strict QMI control-device validation and deterministic resolution of a
  single official-style netifd `devpath`; ambiguous paths fail closed.
- Kept QMI identity available on minimal OpenWrt images without an external
  `timeout` command by falling back to uqmi's bounded per-request timeout.
- Added an internal bounded watchdog for the `sms_tool` AT identity fallback
  when minimal OpenWrt images have no external `timeout` command. A blocked
  serial port now returns a retryable identity result instead of accumulating
  processes and leaving LuCI on an XHR timeout.
- Serialized QMI identity transactions per control device and cache the
  successfully validated sibling AT port in root-owned volatile `/var/run`
  state. Concurrent
  boot reconciliation and LuCI polling can no longer contend for the same
  serial port, while every cached port is revalidated against the selected
  modem's current sysfs topology before use.
- Do not repeat the vendor ICCID command on a serial port whose standard ICCID
  request reached its timeout. Ports that answer immediately with an error or
  unrecognized output still receive the Quectel-compatible fallback, while a
  cold multi-port scan no longer doubles every non-responsive-port delay.
- Classify the internal AT timeout with a root-only watchdog marker rather than
  the terminated process's exit status. This covers `sms_tool` builds that
  catch SIGTERM and return a generic command error instead of signal status.
- Added bounded QMI signal-info collection and a deterministic percentage from
  the best reported RSRP, with RSSI fallback when RSRP is unavailable.
- When QMI confirms home registration but cannot report a separate home/SPN
  identity, LuCI safely reuses the serving name for the SIM-provider and home
  network rows. It never applies that fallback while roaming.
- Retry the full modem/APN/signal status once after ten seconds only when the
  initial LuCI load is incomplete. Continuous polling remains limited to cheap
  action state, avoiding periodic QMI/AT identity traffic; completed actions
  still trigger one immediate panel refresh.
- Added `targets-json` v2 evidence fields so unvalidated implementations are
  distinguishable from hardware-validated support.
- Added the same capability/evidence state to status and detect output; LuCI
  enables QMI APN actions while disabling ModemManager-only roaming controls
  with an explicit backend-specific explanation.
- Removed hard dependencies on ModemManager and button-hotplug support from the
  GUI-independent core; runtime capabilities now reflect installed backend
  commands, while configured unavailable targets remain visible.
- Moved the verified WH3000 BTN_0 hotplug handler and its
  `kmod-button-hotplug` dependency into the optional
  `apn-autoconfig-integration-huasifei-wh3000` package. The core rejects GPIO
  reset without a supported integration marker, and LuCI hides those controls.
- Kept QMI connection ownership in official netifd `qmi.sh`; the engine never
  starts a bearer directly and does not change USB, radio, PIN or SIM state.
- Kept roaming-policy mutation explicitly ModemManager-only instead of
  pretending its UCI option has portable QMI semantics. QMI reports the
  observed roaming state but explicitly marks policy as unsupported and never
  lets a stale `allow_roaming` option block APN detection.
- Increased the bounded QMI teardown quiet period after live RM520N testing
  showed that a two-second restart could race client-ID cleanup and trigger an
  unnecessary SIM power cycle in netifd's `qmi.sh`.
- Ordered QMI board-reset recovery as identity readiness, bounded client
  settle, netifd interface recovery, then APN reconciliation. This prevents a
  direct identity query immediately before `qmi.sh` initialization and avoids
  a redundant recovery `ifup` after the interface is already back.
- When the configured mobile target is unavailable, LuCI now lists discovered
  cellular alternatives and points to Settings → Mobile target. It remains
  fail-closed and never redirects status or mutating actions to another modem
  silently.
- Masked ICCID, IMSI, EID and reconciled SIM identifiers in LuCI by default;
  each value now has an explicit accessible Show/Hide control whose position
  remains fixed while the same-width masked and revealed values are toggled.
- Added synthetic QMI apply, dual-stack fallback, idempotency, button flow,
  exact reset/failure rollback and malformed cross-backend baseline tests,
  alongside home/roaming and same-device AT fixtures and tests for
  unavailable adapters, command failure, malformed identity, sysfs escapes,
  unsafe device paths and mutating-command
  isolation while retaining the full ModemManager regression suite.
- Made baseline reset validate every record before its first UCI write, so a
  malformed trailing record cannot produce a partial restore.
- Fixed portable reading of optional cached profile fields across BusyBox and
  BSD awk implementations.
- Completed the packaged RM520N QMI gate: apply, exact failure rollback,
  dual-stack fallback, reboot, cold LuCI concurrency, bounded read-only soak,
  physical BTN_0/GPIO recovery, `reset-all`, actual package removal and
  reinstall. Restored the production ModemManager configuration afterward and
  repeated registration, APN reconciliation and Internet-connectivity checks.

## apn-autoconfig 0.9.0 / apn-autoconfig-providers 2026.07.18 / luci-app-apn-autoconfig 0.5.0

- Added a versioned `targets-json` inventory with stable `network:<section>`
  IDs, normalized backend names and explicit identity/profile capabilities.
- Added automatic selection when exactly one writable cellular target exists;
  ambiguous and unsupported targets fail with exit code 4 before UCI, network
  or persistent-state mutation.
- Kept ModemManager as the sole functional APN backend in 0.9.0 and exposed
  QMI, MBIM, Fibocom and selected AT-managed protocols as inventory-only
  targets without claiming incomplete support.
- Routed SIM/status and profile operations through a backend dispatch boundary
  so future adapters do not need to alter the APN matcher.
- Replaced the fixed connectivity device assumption with netifd's current
  `l3_device`, retaining `option device` only as a validated fallback.
- Successful idempotent reconciliation now replaces a stale failure result
  after real connectivity has been re-verified.
- Namespaced rollback and active-profile state per target, migrated 0.8.x
  state under the operation lock and added `reset-all` for safe package removal
  after more than one target has been used.
- Propagated the selected target through synchronous CLI calls, narrow
  query/control wrappers and background workers; action status now reports the
  target ID.
- Updated LuCI to list discovered targets and their real write capability and
  to display the selected protocol, backend and effective data device.
- Added contract, ambiguity, path/input validation, unsupported-backend
  isolation, dynamic-device, migration and multi-target removal tests.
- Added `docs/roadmap.md` describing the tentative QMI, MBIM, AT and 1.0/FM350
  sequence. Those later adapters are explicitly outside the 0.9.0 scope.

## apn-autoconfig 0.8.6 / apn-autoconfig-providers 2026.07.18 / luci-app-apn-autoconfig 0.4.1

- Licensing-only release: include the required MIT, Apache-2.0 and CC-PDDC
  notices in APKs and clarify third-party attribution and provenance.
- No runtime functional changes or bug fixes.

## apn-autoconfig 0.8.5 / apn-autoconfig-providers 2026.07.16 / luci-app-apn-autoconfig 0.4.0

- Add manual provider-database update checks and installations through LuCI,
  limited to the independently versioned `apn-autoconfig-providers` package.
- Require the configured project feed and pinned trusted key, refresh only that
  signed repository, and validate a staged database package before installation.
- Serialize database package work with APN, roaming-policy and modem operations
  through the existing background dispatcher and operation lock.
- Persist the last check, available version, result and successful LuCI
  installation time without storing SIM or APN credentials.
- Redesign the LuCI page into distinct mobile-connection, APN, provider-database,
  roaming-policy, action and configuration sections.
- Add bold status labels, native LuCI signal-quality progress visualization,
  responsive spacing and collapsible technical details.
- Preserve the 0.8.2 roaming-policy selection fix and expand its regression test
  to cover the new grouped layout and database controls.

## apn-autoconfig 0.8.2 / apn-autoconfig-providers 2026.07.16 / luci-app-apn-autoconfig 0.3.1

- Correct the initial LuCI roaming-policy selection so the browser cannot
  display `Explicitly block` while OpenWrt is using its default allowed policy.
- Keep the policy Apply button disabled until the user deliberately changes
  the selection, preventing a misleading initial value from being committed.
- Add a browser-semantics regression test for all three roaming-policy states
  before LuCI's first background status refresh.
- Reject release tags that do not match the core package version, and verify
  current package versions against the changelog and installation example.

## apn-autoconfig 0.8.1 / apn-autoconfig-providers 2026.07.16 / luci-app-apn-autoconfig 0.3.0

- Restrict the configured connectivity-test endpoint to HTTP or HTTPS URLs.
- Document the automated provider-update trust boundary and intentional
  root-only cleartext storage of APN profile credentials.
- Pin every GitHub-maintained workflow action to an immutable commit while
  retaining the corresponding release line in comments.
- Remove an unused candidate-score read variable.

## apn-autoconfig 0.8.0 / apn-autoconfig-providers 2026.07.16 / luci-app-apn-autoconfig 0.3.0

- Split the generated provider database into the independently versioned
  `apn-autoconfig-providers` package.
- Make the core depend on the provider package while keeping the runtime
  database path and UCI configuration compatible with 0.7.0.
- Add deterministic database version and format metadata alongside the pinned
  upstream source revisions.
- Expose the database path, version, format, sources and revisions through the
  read-only machine API and show them in LuCI.
- Reject an explicitly declared unsupported database format before any modem or
  network operation.
- Build, inspect and publish three independent APK artifacts with one checksum
  manifest.

## apn-autoconfig 0.7.0 / luci-app-apn-autoconfig 0.2.0

- Resolve and report the matching ModemManager modem alongside the active SIM,
  including home and serving operators, registration and roaming state,
  access technologies, signal quality and manual PLMN selection.
- Add a registration preflight which prevents APN changes when roaming data is
  explicitly blocked, registration is denied, only emergency or messaging
  service is available, or registration is still pending.
- Classify operation results, retry temporary readiness and operation-lock
  contention at boot, and expose intentional roaming-policy blocks as a
  distinct terminal background state.
- Upgrade status and detect JSON to v2 with stable roaming and result fields.
- Keep `network.<interface>.allow_roaming` as the sole source of policy. Normal
  APN operations only read it; explicit policy actions safely edit that exact
  option under the existing operation lock.
- Extend LuCI with roaming banners, serving-network diagnostics and a
  three-state policy control for default, explicitly allowed and explicitly
  blocked data roaming.
- Add a live-verified lifecell Ukraine `internet` override while retaining the
  alternate legacy `speed` profile as a lower-priority fallback.
- Refresh informational provider labels for matching cached profiles and wait
  for netifd readiness after re-enabling roaming before retrying an unchanged
  APN.
- Validate the complete roaming flow on live hardware with a lifecell Ukraine
  SIM registered through Telekom Germany, including policy blocking,
  reboot behavior and recovery without redundant APN cycling.
- Add behavioral coverage for home/roaming identity, explicit policy blocks,
  denied and pending registration, policy editing, blocked actions and bounded
  boot retry semantics.

## 0.6.1

- Add a LuCI checkbox for enabling or disabling automatic reconciliation at
  boot through the existing safe `autostart` option.
- Update checkout and artifact GitHub Actions to their Node.js 24 releases.
- Correct the README description of complete mobile profile application and
  simplify the documented boot-reconciliation toggle.

## 0.6.0

- Replace the three-row demonstration database with a deterministic worldwide
  database generated from GNOME mobile-broadband-provider-info, AOSP and local
  verified overrides.
- Add a versioned 12-column runtime schema and apply APN, username, password,
  authentication and IP-family as one ModemManager profile.
- Support AOSP-style IMSI and ICCID digit masks and exact SPN matching.
- Pin upstream source revisions and include their public-domain and Apache-2.0
  licensing information.
- Add generator fixtures, deterministic-output tests and production database
  validation.
- Cache and reconcile complete profiles, migrate v0.5 baselines, and restore
  every managed UCI option exactly after failure, reset or package removal.
- Select IPv4 or IPv6 connectivity checks from the candidate profile and try
  both families for dual-stack or unspecified profiles.
- Add a weekly unattended source refresh with anomaly gates, complete runtime
  verification and automatic commits for accepted database updates.
- Retain profiles removed by upstream sources as progressively demoted fallback
  candidates instead of deleting known working settings immediately.

## 0.5.0

- Add stable JSON output for SIM/APN status and candidate detection.
- Add a non-blocking job API for APN reconciliation and hardware modem reset.
- Expose one unified busy state for jobs started through LuCI and operations
  started through SSH or the physical button.
- Reject overlapping operations and persist terminal success/failure state in
  a volatile runtime directory.
- Add separate read-only and mutating rpcd entry points with narrow ACLs.
- Add the first `luci-app-apn-autoconfig` package with live status, background
  action polling, physical-button configuration and advanced board settings.
- Keep both virtual action buttons disabled until the core confirms completion;
  polling errors do not incorrectly unlock the controls.
- Route physical-button resets through the same background job API so LuCI
  records their exact action and terminal result instead of reverting to stale
  history after an external operation finishes.
- Extend behavioral tests with valid-JSON, concurrency, external-operation and
  failed-job coverage.

## 0.4.0

- Add a manually callable `modem-reset` command for a bounded GPIO modem power
  cycle followed by dynamic SIM discovery and APN reconciliation.
- Restore modem power and attempt to bring `wwan` back after an interrupted or
  failed reset.
- Install an opt-in OpenWrt button hotplug handler for `BTN_0` release events.
- Keep button automation disabled by default until the manual hardware reset
  has been verified on the target router.
- Serialize hardware resets with normal APN operations to prevent overlapping
  button actions.
- Add `kmod-button-hotplug` as a package dependency and behavioral tests for
  GPIO restoration, APN reconciliation, and release-only button activation.
- Validate the full flow on a WH3000 Pro eMMC with an RM520N-GL: physical
  `BTN_0` release, modem object re-enumeration, changed physical SIM/ICCID,
  automatic Telekom APN selection, real connectivity, and mwan3 recovery.

## 0.3.0

- Add an opt-in procd boot service for delayed, bounded APN reconciliation.
- Keep boot-worker stdout and stderr out of procd's syslog capture so messages
  emitted through `logger` are not duplicated as `daemon.err` entries.
- Keep boot automation disabled by default until explicitly enabled in UCI.
- Retry temporary ModemManager/SIM readiness failures without restarting any
  interface other than the configured WWAN interface.
- Resolve the current primary SIM through the matching ModemManager device on
  every run, because modem and SIM object indices change after a hardware reset.
- Treat the legacy numeric `sim_index` setting as a fallback, preserving
  configurations created by earlier package versions.
- Add behavioral tests for disabled startup, successful retry and exhausted
  retry limits.

## 0.2.2

- Add a manual `reconcile` command that treats ICCID changes as authoritative,
  even when the old APN happens to provide working Internet on the new SIM.
- Persist the last successfully reconciled ICCID/APN in `active.tsv`.
- Avoid restarting WWAN when the same SIM, APN and verified connection are
  already active.
- Keep boot and hotplug automation disabled until manual reconciliation has
  been validated on real hardware.

## 0.2.1

- Make candidate specificity ordering portable to BusyBox `sort`.
- Deduplicate identical APNs after sorting, preserving the most-specific provider.
- Add regression tests for candidate order and duplicate suppression.

## 0.2.0

- Converted the reversible prototype into an OpenWrt source package.
- Added OpenWrt APK metadata, dependencies, conffile declaration and package
  removal hooks.
- Added reproducible OpenWrt 25.12.5 SDK build script and GitHub Actions build.
- Kept all operation manual; no boot or hotplug automation is installed.
- Added stale-lock handling and validation for the configured lock path.
- Kept the bundled provider database explicitly demonstrational.

## 0.1.1

- Added exact baseline restoration and clean manual uninstall behavior.
- Added cache by ICCID, rollback, mwan3-aware connectivity checks and tests.
