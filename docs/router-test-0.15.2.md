# Router test: 0.15.2 corrective release

Date: 2026-08-22

Status: **complete; the published release and signed-feed smoke passed.**

Reference system: Huasifei WH3000 on OpenWrt 25.12.5, with a Quectel
RM520N-GL managed by ModemManager and a Fibocom FM350-GL on the project-owned
`apn_atdial` interface `apnmodem1`. The FM350 contained a roaming SIM with a
100 MB allowance.

No subscriber identity is recorded in this document. Exact pre-test UCI and
runtime snapshots are retained on the router under the 0.15.2 recovery area;
the published 0.15.1 APKs and their verified checksums are retained beside
them for rollback.

## Upgrade and reboot

The installed 0.15.1 defect was reproduced before upgrade:

- automatic target selection failed solely because both writable targets were
  present;
- after reboot the FM350 appeared as `Unidentified (0e8d:7127)` and its
  project-created section was described as user-created;
- the 0.15.1 identity cache existed only in volatile storage.

A harmless targeted 0.15.1 status read populated the legacy volatile identity
records without starting a data connection. The 0.15.2 package upgrade copied
both records synchronously to `/etc/apn-autoconfig-modem/identity`; the source
and destination records matched byte-for-byte.

After reboot:

- both `network:wwan` and `network:apnmodem1` were present and `managed:true`;
- the RM520N-GL was `usb-serial` / `modemmanager` / `wwan`;
- the FM350-GL was displayed by model and manufacturer, reported
  `netifd-direct` / `apnmodem1` / `already_provisioned`, and was no longer
  described as unidentified or user-created;
- discovery remained read-only: the FM350 began at `weak-vidpid`, with no
  current-enumeration IMEI proof, and a targeted status read then promoted it
  to the IMEI tier;
- a second reboot again preserved the display identity without treating the
  old IMEI as proof for a possibly replaced physical modem;
- AT-dial `0.15.2-r2` resolved the deliberate post-reboot demotion before port
  lookup, so the old false `modem imei:… is not present` error did not recur.

The repeated notice emitted by inventory polling was found during this pass and
fixed in modem package revision `0.15.2-r2`; its regression test confirms that
`inventory-json` reports the recovered binding without writing the same notice
to syslog on each refresh. After installing the official `r2` APK, two
consecutive hardware inventory calls left the matching journal count unchanged
at `7 -> 7`.

## Automatic two-target reconciliation

An unscoped `apn-autoconfig reconcile` reached both managed targets in route
metric order:

- `network:wwan` selected and verified `web.vodafone.de`, remained up, and
  returned success;
- `network:apnmodem1` was registered in roaming, retained its APN profile,
  remained down, and returned the intentional roaming-policy block;
- the aggregate summary was `1 succeeded, 1 blocked, 0 retryable, 0 failed`
  with exit code 2.

This proves both that a second modem no longer stops automatic operation and
that one successful target cannot hide a blocked second target.

## Bounded roaming cycle

The policy change was scoped explicitly to `network:apnmodem1`. A shell trap
restored `explicit-block` and stopped the interface on every exit path; Wi-Fi
at metric 100 and the RM520 at metric 200 remained ahead of the FM350 at metric
1024 for ordinary traffic.

Observed sequence:

1. policy changed to `explicit-allow`;
2. the FM350 registered in roaming on PLMN 26201;
3. the provider database selected APN `internet` for lifecell (Ukraine);
4. the bound connectivity check succeeded;
5. policy changed to `explicit-block` and `apnmodem1` returned to `up=false`.

The FM350 interface counters measured 4,284 received bytes and 3,083
transmitted bytes, 7,367 bytes total (about 0.007 MB). This is far below both
the 5 MB test budget and the SIM's 100 MB allowance.

## Gates

- `sh scripts/verify.sh`: passed, including all behavioral, modem, AT-dial,
  lifecycle, provider, installer and LuCI regression tests.
- Official OpenWrt 25.12.5 SDK build and APK inspection: passed for the final
  package set in GitHub Actions run
  [32534114023](https://github.com/DarthAnwalt/openwrt-apn-autoconfig/actions/runs/32534114023).
- APK SHA256 verification: passed before every router installation.
- Final installed/recovery package set: core, WH3000 integration, providers and
  LuCI at `r1`; modem and AT-dial at `r2`. All six files match the final
  workflow's `SHA256SUMS`.
- Reboot, persistent display identity, current-enumeration revalidation,
  two-target automatic reconciliation, blocked-roaming aggregation and bounded
  roaming connection: passed on hardware.
- Authenticated LuCI pass: passed. Automatic mode showed both modem cards, the
  Fibocom model and project ownership, with neither `Target unavailable` nor
  the old multiple-target error. Its APN panel explained that reconciliation
  covers both targets and kept roaming controls disabled until one was chosen.
  Selecting `apnmodem1` refreshed the header and panel to that target, displayed
  roaming plus `Explicitly block`, and scoped the policy text to
  `network.apnmodem1`; returning to Automatic restored the two-modem view.
  Settings showed `Automatic (every writable target)`. No browser console
  errors were recorded and no setting was saved or changed during the pass.

## Publication and signed-feed smoke

PR [#43](https://github.com/DarthAnwalt/openwrt-apn-autoconfig/pull/43)
passed its required official-SDK build and was squash-merged to main commit
`5b4fc5b`. Annotated tag `v0.15.2` names that exact commit. Release workflow
[32552652875](https://github.com/DarthAnwalt/openwrt-apn-autoconfig/actions/runs/32552652875)
completed all three jobs successfully: `test-and-build`, `publish-release` and
`publish-repository`.

The public GitHub Release contains six APKs and `SHA256SUMS`. A fresh download
of every asset passed `sha256sum -c`; the modem and AT-dial packages are `r2`,
the other code packages are `r1`, and the provider database is
`2026.08.10-r1`.

Before changing the router, its UCI configuration, APK world, installed package
set, target inventory and both interface states were saved under
`/mnt/storage/recovery/openwrt-25.12.5-pre-alpha/snapshots/` with a checksum
manifest. The smoke then established all of the following without enabling the
FM350 or using its roaming allowance:

- `apk update` accepted the project `packages.adb` with the pinned public key
  and no `--allow-untrusted` option;
- package policy exposed the exact published version of all six packages from
  the public project repository;
- an uncached repository fetch downloaded all six APKs, and every payload
  matched the GitHub Release checksum;
- the six checksum-bound entries left by local test installations were
  normalized to bare names in `/etc/apk/world`;
- a controlled removal and fresh `apk add` installed exactly the six project
  packages from the signed feed. A preflight simulation showed that no system
  package would be removed, and the prepared recovery fallback was not used.

An attempted same-version `--force-reinstall` was deliberately not counted as
evidence: APK reported `APK unavailable, skipped` for the locally built package
identities even though it exited zero. Removing only the six project packages
first made repository selection unambiguous and produced real install and
post-install events for each package.

The lifecycle removal correctly restored the saved pre-package profile, which
removed the project-selected `network.apnmodem1.apn`. Because roaming was still
explicitly blocked, the subsequent automatic reconcile intentionally refused
to modify that target's profile: it returned one success plus one blocked target
with exit code 2. The single APN option was therefore restored from the recovery
snapshot without starting the FM350. After that restoration, both `network`
and application UCI exports matched their pre-smoke snapshots byte-for-byte and
`uci changes` was empty.

Final state:

- all six exact release versions are installed and APK world contains only bare
  project package names;
- `network:wwan` and `network:apnmodem1` both report `managed:true`;
- the RM520N-GL remains up under ModemManager;
- the Fibocom FM350-GL remains recognised as the package-owned `netifd-direct`
  target, down, with `allow_roaming=0`;
- both persistent modem identity records remain present.

The post-publication signed-feed gate passed.
