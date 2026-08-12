# 0.9.2 stabilization test strategy

Version 0.9.2 is a hardening release between the hardware-validated QMI 0.9.1
line and the planned MBIM adapter. It adds no backend capability or validation
claim. The complete 0.9.1 ModemManager/QMI regression suite remains binding.

## Automated gate

`sh scripts/verify.sh` must cover:

- exact ModemManager and QMI apply, failure rollback, reset and idempotency;
- a real `SIGTERM` during the QMI teardown quiet period, followed by exact
  restoration of APN, credentials, authentication, IP family and interface;
- signal forwarding by both the procd boot worker and background action worker;
- `0600` baseline, active-profile, credential-cache and action-state files,
  with target state directories restricted to `0700`;
- rejection of carriage returns in backend/state values;
- rejection of QMI devpaths whose symlinks escape the configured sysfs tree;
- rejection of legacy baselines that belong to another selected interface;
- unchanged QMI/ModemManager option mapping after the shared profile refactor.

The official OpenWrt 25.12.5 SDK build and APK install/upgrade/removal
simulation must also pass before tagging `v0.9.2`.

## Required hardware gate

On the reference Huasifei WH3000 Pro with RM520N-GL, record:

1. upgrade from the published 0.9.1 packages without UCI drift;
2. successful QMI reconciliation and real Internet verification;
3. failed-candidate rollback with the exact original QMI profile restored;
4. service stop during an active QMI reconciliation, confirming the interface
   returns up with the original profile within procd's termination window;
5. reboot reconciliation, LuCI background action, BTN_0 recovery and
   `reset-all`/package-removal smoke tests;
6. final reinstall and installed-package status evidence.

These hardware items are pending until explicitly recorded below. A green
synthetic suite or SDK build alone is not sufficient to publish 0.9.2.

## Recorded evidence

- Synthetic/fixture gate: passed locally on 2026-08-11 with
  `sh scripts/verify.sh` (`Static and behavioral verification passed`).
- Official SDK and APK simulation: pending.
- Reference-router hardware gate: pending.
