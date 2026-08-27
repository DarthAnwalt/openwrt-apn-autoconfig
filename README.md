# apn-autoconfig 0.2.1 — OpenWrt source package

`apn-autoconfig` is a small POSIX-shell helper for a ModemManager interface on
OpenWrt. It reads SIM identity with `mmcli -i 0`, finds APN candidates in a
local TSV database, restarts only the configured mobile interface, verifies
real Internet access through `wwan0` with `curl`, caches the successful APN by
ICCID, and restores the previous APN when all candidates fail.

This repository is an OpenWrt source package. It builds a normal `.apk` with
the official OpenWrt 25.12 SDK. It is still an MVP, not a finished worldwide
provider database and not a LuCI application.

The implementation is MIT licensed; see `LICENSE`.

## Safety model

- `detect` and `status` are read-only.
- `apply` edits only `network.<interface>.apn` (default: `network.wwan.apn`).
- It calls only `ifdown wwan` / `ifup wwan`; it does not reload or restart the
  whole network.
- It does not edit mwan3 interfaces, members, policies, rules, or metrics.
- If mwan3 is available, the connectivity test is run using
  `mwan3 use wwan curl ...` so the test follows the selected WAN routing table.
- An interrupted or failed `apply` restores the prior APN and restarts only
  `wwan`.
- Before the first `apply`, the original APN state is stored persistently in
  `/etc/apn-autoconfig/baseline.tsv`.
- `reset` restores that pre-test APN state and removes generated cache.
- `apk del apn-autoconfig` runs `reset` before deleting any files. If reset
  fails, package removal is aborted and the program remains available for
  diagnosis and retry.
- A lock prevents two simultaneous `apply` runs.
- No automatic boot/hotplug trigger is installed in this MVP.

Existing client connections over the mobile link will naturally be interrupted
while APNs are tested. Other working mwan3 uplinks should remain available.

## Requirements

- vanilla OpenWrt 25.12
- `modemmanager` / `mmcli`
- `curl`
- a configured netifd ModemManager interface named `wwan`
- its data device named `wwan0`
- optional: `mwan3`

The defaults match the Huasifei WH3000 Pro + Quectel RM520N-GL setup for which
this MVP was prepared. Edit `/etc/config/apn-autoconfig` for other names.

## Building the APK

The package is built with the official OpenWrt 25.12.5 mediatek/filogic SDK.
On Linux x86_64:

```sh
sh scripts/build-with-sdk.sh
```

The resulting package and checksum are written to `dist/`. On macOS, use the
included GitHub Actions workflow because the official SDK is a Linux x86_64
toolchain.

Install a locally built package on OpenWrt 25.12 with:

```sh
apk add --allow-untrusted ./apn-autoconfig-0.2.1-r1.apk
```

The package owns:

```text
/usr/sbin/apn-autoconfig
/usr/share/apn-autoconfig/providers.tsv
/etc/config/apn-autoconfig
```

The UCI file is declared as a package configuration file. Cache files are
created later under `/etc/apn-autoconfig/cache/`.

## First use

Start with the read-only command:

```sh
apn-autoconfig detect
```

It prints SIM identifiers and matching APN candidates. Review them before
running:

```sh
apn-autoconfig apply
```

Show the current configuration and cached result with:

```sh
apn-autoconfig status
```

Return to the APN state that existed before the first `apply`:

```sh
apn-autoconfig reset
```

`reset` restarts only `wwan`. It does not change mwan3, Travelmate, firewall,
DNS, WireGuard, ZeroTier, or any other network interface.

Logs use the tag `apn-autoconfig`:

```sh
logread | grep apn-autoconfig
```

## What `apply` does

Candidate order is:

1. the APN cached for the current ICCID;
2. matching rows from the local TSV, most specific first and then by priority;
3. optionally an empty APN when `option try_empty '1'` is configured.

For each candidate the helper:

1. writes the APN through UCI and commits `network`;
2. runs `ifdown wwan`, then `ifup wwan`;
3. waits until netifd reports the interface as up;
4. runs an HTTPS request through `wwan0` with `curl`;
5. caches a successful result by ICCID.

If every candidate fails, the original APN (including an originally absent or
empty setting) is restored and `wwan` alone is restarted.

## Configuration

Default `/etc/config/apn-autoconfig`:

```text
config apn_autoconfig 'main'
        option interface 'wwan'
        option sim_index '0'
        option device 'wwan0'
        option database '/usr/share/apn-autoconfig/providers.tsv'
        option cache_dir '/etc/apn-autoconfig/cache'
        option state_dir '/etc/apn-autoconfig'
        option test_url 'https://connectivitycheck.gstatic.com/generate_204'
        option wait_seconds '35'
        option try_empty '0'
        option use_mwan3 'auto'
        option lock_dir '/var/lock/apn-autoconfig.lock'
```

`use_mwan3` accepts `auto`, `always`, or `never`. `auto` uses `mwan3 use` only
when mwan3 exists and knows the configured interface.

`try_empty` is disabled by default because an empty APN can yield a formally
connected bearer with an IP address but no return traffic. Enable it only if
you deliberately want it as the final fallback.

## Demo TSV database

The bundled database contains only the two configurations verified while
building this MVP:

- Telekom Germany / Kaufland Mobil: `internet.telekom`
- Vodafone Germany: `web.vodafone.de`

It is explicitly **not** a worldwide APN database.

The schema is tab-separated:

```text
mccmnc  imsi_prefix  iccid_prefix  gid1  spn_substring  provider  apn  priority
```

Use `-` for an unconstrained matching field. More specific rows win; `priority`
orders equally specific candidates. A generated worldwide database can replace
`/usr/share/apn-autoconfig/providers.tsv` without changing the program.

Example:

```text
26201  -  -  01  Kaufland Mobil  Kaufland Mobil (Telekom DE)  internet.telekom  10
```

The file must contain literal TAB characters, not spaces.

The MVP applies the APN field only. Username, password, authentication type,
MVNO-specific rules beyond the listed matching fields, and automatic conversion
from `mobile-broadband-provider-info` are future work.

## Cache

Successful results are stored as one small TSV file per ICCID:

```text
/etc/apn-autoconfig/cache/<ICCID>.tsv
```

The cache is tried before the database. Remove one file to force fresh
detection for that SIM.

## Exact rollback and package removal

The first `apply` creates a persistent baseline recording both the original APN
value and whether the UCI APN option originally existed at all. Consequently,
an originally absent option is removed again rather than restored as an empty
option.

To undo testing but keep the package installed:

```sh
apn-autoconfig reset
```

To restore the baseline and remove the package:

```sh
apk del apn-autoconfig
```

The package pre-deinstall script restores the baseline first. If restoration
fails, removal aborts. After a successful reset, package removal deletes:

```text
/usr/sbin/apn-autoconfig
/usr/share/apn-autoconfig/providers.tsv
/etc/config/apn-autoconfig
/etc/apn-autoconfig/             (baseline and cache)
```

Removal deliberately deletes this package's modified UCI configuration instead
of leaving a package-manager configuration remnant. It does not modify mwan3,
Travelmate, firewall, DNS, WireGuard, ZeroTier or any unrelated interface.

The program does not install or enable an automatic startup task.

## Attended sysupgrade

This package is not yet in an official OpenWrt feed. A local `.apk` is therefore
not guaranteed to be included by the public Attended Sysupgrade server. Do not
assume seamless ASU preservation until a custom signed feed or an official feed
submission has been implemented and tested.

## Known limitations

- The bundled database is deliberately tiny.
- SIM index is currently configured explicitly (default `0`).
- Only the APN is applied; APN username/password/authentication are not.
- The connectivity test is IPv4 HTTPS through one configured net device.
- No hotplug automation and no LuCI UI are included.
- A provider missing from the TSV requires a manual APN or a larger generated
  database.

These limits are intentional for a first version whose failure mode is safe and
understandable.
