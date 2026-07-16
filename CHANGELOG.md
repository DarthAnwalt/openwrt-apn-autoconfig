# Changelog

## apn-autoconfig 0.7.0 / luci-app-apn-autoconfig 0.2.0

- Resolve and report the matching ModemManager modem alongside the active SIM,
  including home and serving operators, registration and roaming state,
  access technologies, signal quality and manual PLMN selection.
- Add a registration preflight which prevents APN changes when roaming data is
  explicitly blocked, registration is denied, only emergency or messaging
  service is available, or registration is still pending.
- Classify operation results and make only registration-pending failures
  retryable at boot; expose intentional roaming-policy blocks as a distinct
  terminal background state.
- Upgrade status and detect JSON to v2 with stable roaming and result fields.
- Keep `network.<interface>.allow_roaming` as the sole source of policy. Normal
  APN operations only read it; explicit policy actions safely edit that exact
  option under the existing operation lock.
- Extend LuCI with roaming banners, serving-network diagnostics and a
  three-state policy control for default, explicitly allowed and explicitly
  blocked data roaming.
- Add a live-verified lifecell Ukraine `internet` override while retaining the
  alternate legacy `speed` profile as a lower-priority fallback.
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
