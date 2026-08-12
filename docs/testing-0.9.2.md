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
- Official SDK and APK simulation: passed in GitHub Actions run
  `31598055359` for commit `4018653e64a0409b8c85104e13281c5838b0bdda`.
  The downloaded artifact digest was
  `sha256:255b9d5fe61e378e13c90a1a71de367aa46854a55696e5ddf35dae0733b58d8d`;
  every APK matched the included `SHA256SUMS`. Router-side simulation proposed
  only the expected core, integration and provider-database upgrades.
- Reference-router partial gate on 2026-08-12: upgrading the production
  ModemManager installation from core/integration 0.9.1 to 0.9.2 and providers
  2026.07.27 to 2026.08.10 left `network`, `apn-autoconfig`, `mwan3` and
  `travelmate` byte-identical and UCI clean. Travelmate and LTE both returned
  HTTP 204 after the transaction.
- Isolated QMI apply and real Internet verification passed on the reference
  RM520N-GL. A forced single invalid APN failed as intended, restored all QMI
  UCI values, restored the physical 3GPP profile byte-for-byte and returned the
  bearer with HTTP 204.
- Stopping the procd service after the invalid APN had been written forwarded
  termination to the active engine. It restored the original UCI and physical
  profile, restarted QMI and left no worker or adapter process behind. The
  rollback issued the recovery `ifup` after its six-second quiet period;
  subsequent RM520N registration and DHCP completed 36 seconds after stop.
- The packaged background reconcile action completed successfully against the
  isolated QMI target and recorded the final v2 action state as `success`.
- The reboot experiment with deliberately volatile target state was not a
  valid idempotent-reconcile gate: `/tmp` state disappeared at boot and an
  intentionally shortened ten-second delay started a full candidate cycle
  before the RM520N had settled. Rollback retained a working QMI profile and
  HTTP connectivity. A later attempt to prepare persistent isolated state was
  stopped after QMI identity stalled; no reboot evidence is claimed from it.
  The production ModemManager configuration was restored byte-for-byte, both
  Travelmate and LTE returned online, HTTP succeeded through both paths and
  UCI was clean after a final router reboot.
- A clean repeat with target baseline/cache on persistent storage and the
  normal 30-second boot delay passed on 2026-08-12: the boot worker exited 0,
  reported the SIM as already reconciled without changing the profile, QMI
  and Travelmate both returned HTTP 204, UCI was clean and the physical 3GPP
  profile before/after reboot had the same SHA-256.
- The first BTN_0 hotplug repeat exposed a hardware-only readiness race. The
  parent QMI interface became `up` while `qmi.sh` was still establishing the
  dynamic data bearer; an immediate identity query then competed with netifd
  and the worker ended retryable. The corrected candidate waits for an
  addressed `${interface}_4` or `${interface}_6` data interface. Repeating the
  same installed hotplug handler with the original five-second GPIO power-off
  completed in 76 seconds, recorded action state `success`, kept the physical
  profile byte-identical, returned QMI and Travelmate HTTP 204 and left UCI
  clean. The event was injected into the installed hotplug handler with
  `BUTTON=BTN_0 ACTION=released`; the board GPIO, worker and recovery path were
  real, but the mechanical switch itself was not pressed in this repeat.

The reference-router gate therefore remains open only for the corrected
official-SDK artifact, `reset-all`/package removal and the final
reinstall/status capture. Do not tag or publish 0.9.2 before those steps pass.
