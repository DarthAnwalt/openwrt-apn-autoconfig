# 0.9.1 alpha production-router compatibility test

This procedure is only a regression check for the already validated Huasifei
WH3000 Pro + RM520N + ModemManager setup. It is not evidence that the QMI alpha
works on hardware.

## Stop conditions

Do not install the alpha unless all of the following are true:

- a second working management path is available, preferably Ethernet;
- the exact stable 0.9.0 core, provider and 0.5.0 LuCI APKs are already in
  `/tmp/apn-autoconfig-rollback/` on the router;
- their SHA-256 hashes match the published 0.9.0 release checksums;
- the current UCI and engine state backup has been copied off the router;
- `apk add --simulate` accepts both the alpha transaction and the rollback
  transaction;
- no unrelated package upgrade is included in either transaction.

Do not test QMI, change the working `wwan` protocol, remove ModemManager or
change the modem USB mode on this router.

## Backup

Create a root-only archive before installing anything:

```sh
umask 077
mkdir -p /tmp/apn-autoconfig-rollback
tar -czf /tmp/apn-autoconfig-pre-0.9.1-alpha.tar.gz \
  /etc/config/apn-autoconfig \
  /etc/config/network \
  /etc/apn-autoconfig 2>/dev/null
sha256sum /tmp/apn-autoconfig-pre-0.9.1-alpha.tar.gz
```

Copy this archive to another machine. The copy on `/tmp` is lost on reboot.
Record the installed packages, target inventory, status and pending UCI changes:

```sh
apk list --installed | grep -E '^(apn-autoconfig|luci-app-apn-autoconfig)-'
apn-autoconfig targets-json
apn-autoconfig status-json
uci changes
```

## Required package simulation

Upload the four alpha APKs to `/tmp/apn-autoconfig-alpha/`. First simulate the
complete installation:

```sh
apk add --simulate --allow-untrusted \
  /tmp/apn-autoconfig-alpha/apn-autoconfig-providers-*.apk \
  /tmp/apn-autoconfig-alpha/apn-autoconfig-0.9.1_alpha1-r1.apk \
  /tmp/apn-autoconfig-alpha/luci-app-apn-autoconfig-0.6.0_alpha1-r4.apk \
  /tmp/apn-autoconfig-alpha/apn-autoconfig-integration-huasifei-wh3000-*.apk
```

Use the exact filenames produced by the SDK if APK normalizes the alpha version
differently. Abort if the simulation proposes removing ModemManager, netifd or
any unrelated package.

Then prove that the local stable packages form an accepted rollback. The
Huasifei integration must be removed before 0.9.0 takes ownership of the old
button handler again:

```sh
apk del --simulate apn-autoconfig-integration-huasifei-wh3000
apk add --simulate --allow-untrusted \
  /tmp/apn-autoconfig-rollback/apn-autoconfig-providers-2026.07.18-r1.apk \
  /tmp/apn-autoconfig-rollback/apn-autoconfig-0.9.0-r1.apk \
  /tmp/apn-autoconfig-rollback/luci-app-apn-autoconfig-0.5.0-r1.apk
```

## Narrow alpha regression scope

After a successful simulation, install all four alpha packages in one
transaction. Verify that the selected target remains the existing
ModemManager-backed `wwan`, the current APN is unchanged, the interface is up
and normal Internet access remains available. Exercise only the existing
ModemManager workflow: status, detection, idempotent reconciliation and—after
manual confirmation of the marker and GPIO configuration—the known WH3000
button flow.

Do not continue after any unexpected target selection, package removal, UCI
change, loss of the management path or rollback warning.

## Observed WH3000 result (2026-07-19)

The optional integration package received one `BTN_0` release and queued one
background `modem-reset`. The engine stopped `wwan`, held modem power off for
the configured five seconds, restored power, found ModemManager and the SIM
again after 44 seconds, and completed reconciliation after 55 seconds total.
`wwan0` returned up, the configured APN was unchanged, the operation lock was
released and `uci changes` remained empty.

## Rollback

Remove the alpha-only integration first, then install the three stable packages
from local storage:

```sh
apk del apn-autoconfig-integration-huasifei-wh3000
apk add --allow-untrusted \
  /tmp/apn-autoconfig-rollback/apn-autoconfig-providers-2026.07.18-r1.apk \
  /tmp/apn-autoconfig-rollback/apn-autoconfig-0.9.0-r1.apk \
  /tmp/apn-autoconfig-rollback/luci-app-apn-autoconfig-0.5.0-r1.apk
```

Run `apn-autoconfig status-json` and check `wwan` immediately. Restore the
backup archive only if the stable package rollback did not preserve the known
configuration; do not overwrite `/etc/config/network` blindly while connected
only through the cellular interface.
