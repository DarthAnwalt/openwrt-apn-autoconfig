# 0.10.1 WH3000 hardware validation record

Date: 2026-08-14
Status: hardware and package gates passed; publication and the live signed-feed
smoke remain open.

## Test system

- Huasifei WH3000 Pro eMMC running OpenWrt 25.12.5 (r33051-f5dae5ece4),
  `apk-tools 3.0.5`;
- internal Quectel RM520N-GL owned by ModemManager, netifd target `wwan`,
  APN unchanged throughout;
- `travelmate` and `mwan3` installed; the router's primary uplink is WiFi and
  the modem is the backup path, so modem power-cycles do not interrupt the
  administrative session. A passing test therefore has to prove the modem path
  itself, not merely that the router stayed reachable;
- packages built by GitHub Actions run `31824195430` from PR 29, installed from
  checksum-verified local artifacts;
- recovery point captured before the first mutation and stored on the
  persistent partition beside the existing `pre-0.8.x` points;
- modem and SIM identifiers intentionally omitted from this record.

## Upgrade

Live `apk` upgrade from the released 0.10.0 to 0.10.1 for `apn-autoconfig`,
`apn-autoconfig-modem` and the WH3000 integration, in one transaction. Both
configuration files were preserved as conffiles (`.apk-new` written, existing
values untouched): the pinned `reset_modem_id`, the enabled `BTN_0` setting and
the configured APN all survived. `wwan` stayed up across the upgrade and no
operation lock was left behind.

`apk manifest` confirmed the installed `apn-autoconfig-modem` file list, and
`apk audit --system` reported no unexpected modification of project files. All
executables are mode 0755. This closes the APK-inspection gate that could not be
performed on the maintainer's macOS host, where no apk v3 tool exists.

The new lock protocol is present in all three installed implementations
(`apn-autoconfig`, `apn-autoconfig-modem`, `apn-autoconfig-qmi`).

## Reset matrix

All three paths were exercised against the new lock protocol, because the
0.10.0 hardware evidence was obtained against the protocol this patch replaces.

**Compatibility `apn-autoconfig modem-reset`.** Exit 0 in 58 s wall clock. The
GPIO returned to its powered-on value, both operation locks were clear, `wwan`
came back on `wwan0`, the SIM was found already reconciled with the configured
APN, and the configured connectivity check passed over the modem interface.

**Interruption.** A real `SIGTERM` was delivered inside the destructive window,
synchronised on disappearance of the selected control device rather than on the
GPIO value file, per the oracle established in `router-test-0.10.0.md`. The
coordinator had logged the power-off before the signal arrived. It exited 143,
restored the powered-on GPIO value and released both locks. `wwan` recovered
automatically about 25 s later and a real HTTPS request over `wwan0` succeeded;
inventory returned to `owner_state: modemmanager`, unambiguous, reset-capable.

An earlier attempt at this test was discarded rather than recorded: BusyBox
`sleep` rejects fractional arguments, so the synchronisation loop degenerated
into a busy loop and the signal arrived before the destructive phase. The
post-conditions looked correct but proved nothing, so the test was repeated with
integer polling and an explicit assertion that the power-off had been logged.

**`BTN_0` duplicate release.** This is the specific window the 0.10.1 defect
corrupted, so it was exercised deliberately. A press event was ignored. The
first release was accepted. A second release issued immediately afterwards —
aimed at the launcher-to-worker handoff — and a third issued during the running
operation were both logged as `duplicate ignored`, and every handler invocation
exited 0. Router evidence shows three release events, exactly **one** power-off
and exactly **one** terminal result (`success`, exit code 0). Under 0.10.0 a
release landing in that window was reported as a rejected launch and returned a
hotplug failure.

## Router-clock timing

From router log timestamps, for the successful compatibility reset:

| Stage | Observed |
|---|---:|
| Configured power-off interval | 5 s |
| Power restored to original ModemManager owner returned | 42 s |
| Owner returned to readable primary SIM and reconcile start | 5 s |
| Reconcile to verified connectivity | 3 s |
| Power-off start to verified connectivity | 55 s |

The 42 s owner wait is now bounded by a wall clock against the configured 90 s.
Under the previous iteration-counting code the same configured value permitted
roughly 135 s of real time, because the duration of each inventory scan was not
subtracted. The measured figures remain consistent with the 0.10.0 record
(39 s and 52 s respectively), so the fix did not slow the path down.

## Package lifecycle

Removal simulation selected exactly the five project packages and nothing else.
Actual removal and reinstall are deferred to the post-publication smoke so that
they exercise the signed feed rather than local artifacts.

## Open

- publication of the release tag and the signed feed; and
- the live feed install/removal/reinstall smoke without `--allow-untrusted`.
