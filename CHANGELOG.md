# Changelog

## apn-autoconfig 0.9.1_alpha1 / apn-autoconfig-providers 2026.07.18 / luci-app-apn-autoconfig 0.6.0_alpha1 (unreleased)

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
- Added `targets-json` v2 evidence fields so alpha and unvalidated implementation is
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
- Documented the remaining packaged end-to-end, failure, reboot and soak gates.
  This alpha is not yet the stable 0.9.1 release.

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
