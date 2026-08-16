# 0.12.0 WH3000 package and upgrade validation

Date: 2026-08-16
Status: package, upgrade and read-only interface checks complete. The native
MBIM hardware run is **not** in this record — it requires switching the module's
USB composition and is covered separately by the pre-flight in
[`testing-0.12.0.md`](testing-0.12.0.md). MBIM therefore remains
`implementation_state: alpha`, `validation_state: synthetic`.

## Environment

- OpenWrt 25.12.5 r33051-f5dae5ece4 on the Huasifei WH3000 Pro eMMC, apk 3.x;
- internal Quectel RM520N-GL in its QMI composition, owned by ModemManager,
  netifd target `wwan`, APN unchanged throughout;
- the router's primary uplink is WiFi and the modem is the backup path, so an
  administrative session surviving is never by itself evidence;
- packages built by GitHub Actions from PR 32 with the official OpenWrt 25.12.5
  SDK, installed from checksum-verified local artifacts;
- recovery point captured before the first mutation and stored on the persistent
  partition beside the earlier ones;
- modem and SIM identifiers intentionally omitted from this record.

## SDK gate, including a failure worth recording

The first SDK run **failed**, and correctly so. The build inspects the produced
APK against an exact expected file list and count, and the new
`usr/libexec/apn-autoconfig-mbim` made it 14 files where 13 were declared. An
unlisted file inside a published package is exactly what that gate exists to
catch; the expectation was updated rather than relaxed, and the rebuild passed.

## Live upgrade

All five packages' checksums were verified on the router before installation.
`apk add` then upgraded `apn-autoconfig`, `apn-autoconfig-modem`, the Huasifei
integration and `luci-app-apn-autoconfig` from 0.11.0 to 0.12.0 in one
transaction, with the provider database unchanged at its date version.

Configuration survived: the selected interface, the enabled `BTN_0`, the pinned
`reset_modem_id` and the configured APN are all unchanged. `wwan` stayed up
across the upgrade, no operation lock was left behind, and `apk audit` reports
only the expected user-modified conffiles and added service links.

Both configuration files were preserved as conffiles with `.apk-new` written
beside them. This repeats the 0.11.0 finding and is worth stating again as a
rule rather than an observation: **a new configuration default does not reach an
existing installation.** Anything that must take effect on upgrade cannot be
introduced as a config option alone.

## Read-only checks after the upgrade

- The MBIM adapter is installed and reports its capabilities as available on
  this router, since `umbim` ships in the base system. That is a capability
  statement, not a hardware claim.
- `targets-json` and `status-json` now carry the additive
  `roaming_policy_read` / `roaming_policy_write` booleans. The ModemManager
  target is unchanged and still `stable` / `hardware` / `hardware_validated`,
  and its identity, registration, serving operator, access technology and signal
  are all read exactly as before.
- Inventory reports the production modem with unchanged stable identity,
  `protocol=qmi`, `owner_state=modemmanager` and no ambiguity.
- `provision-plan` for the production modem answers `already_configured` with
  the blocked exit class and leaves no pending UCI change. The refusal path is
  unaffected by the MBIM work.
- The narrow rpcd surface is unchanged: the ACL grants `exec` on the four
  wrappers only, and the mutating wrapper exposes a fixed verb list that
  includes the three roaming-policy verbs the LuCI control uses.

## Still open

1. The LuCI page in a real browser. The 0.11.0 run found a defect there that no
   fixture could have caught, so this is a required step, performed by the
   maintainer rather than from a script.
2. The native MBIM hardware run: composition switch, discovery, provisioning,
   profile write, verification, roaming policy, rollback and restore.
3. The signed-feed install/removal/reinstall smoke, which is only possible after
   publication.
