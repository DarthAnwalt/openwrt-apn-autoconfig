# Changelog

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
