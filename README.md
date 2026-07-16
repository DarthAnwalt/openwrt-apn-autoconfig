# apn-autoconfig — OpenWrt source packages

`apn-autoconfig` is a small POSIX-shell helper for a ModemManager interface on
OpenWrt. It dynamically resolves the active ModemManager SIM, finds mobile
profile candidates in a worldwide local TSV database, restarts only the configured mobile
interface, verifies real Internet access through `wwan0` with `curl`, caches
the successful profile by ICCID, and restores the previous profile when all candidates
fail. It distinguishes the SIM's home operator from the serving network,
honors OpenWrt's canonical data-roaming policy before changing any APN, and
reports registration failures separately from profile failures. It includes an idempotent `reconcile` command for SIM transitions and an
opt-in delayed boot service. It can also power-cycle a modem through an
exported GPIO and reconcile
the APN after the modem returns. Boot and hardware-button automation are both
disabled by default.

This repository contains three OpenWrt source packages. It builds normal `.apk`
packages with the official OpenWrt 25.12 SDK:

- `apn-autoconfig`, the POSIX-shell core;
- `apn-autoconfig-providers`, the independently versioned provider database;
- `luci-app-apn-autoconfig`, the optional web interface.

The generated provider database combines GNOME mobile-broadband-provider-info,
the AOSP sample APN database and locally verified overrides. Large upstream XML
files are converted at development time into a compact TSV installed on the
router.

The implementation is MIT licensed. Imported AOSP data is Apache-2.0 and the
GNOME provider database is dedicated to the public domain; see `LICENSE` and
`data/licenses/`.

## Safety model

- `detect` and `status` are read-only.
- Normal APN operations never write `network.<interface>.allow_roaming`; the
  existing OpenWrt network option remains the sole source of roaming policy.
- `apply` edits only the ModemManager profile options `apn`, `username`,
  `password`, `allowedauth` and `iptype` under `network.<interface>`.
- It calls only `ifdown wwan` / `ifup wwan`; it does not reload or restart the
  whole network.
- It does not edit mwan3 interfaces, members, policies, rules, or metrics.
- If mwan3 is available, the connectivity test is run using
  `mwan3 use wwan curl ...` so the test follows the selected WAN routing table.
- An interrupted or failed `apply` restores the prior mobile profile and restarts only
  `wwan`.
- Before the first `apply`, the original profile state is stored persistently in
  `/etc/apn-autoconfig/baseline.tsv`.
- `reset` restores that pre-test profile state and removes generated cache.
- `apk del apn-autoconfig` runs `reset` before deleting any files. If reset
  fails, package removal is aborted and the program remains available for
  diagnosis and retry.
- A lock prevents two simultaneous `apply` runs.
- The boot service is installed but inert while `option autostart '0'` remains
  configured.
- The button handler is installed but inert while `option button_enabled '0'`
  remains configured.
- A modem reset uses the same operation lock as APN changes. Repeated button
  presses cannot start overlapping resets.
- LuCI starts long operations in the background. Both virtual action buttons
  remain disabled while the core reports a queued, running, SSH-initiated or
  physical-button-initiated operation.
- A lost or invalid polling response does not falsely mark an operation as
  finished. The buttons are re-enabled only after a successful status response
  reports a terminal state.
- If the reset command is interrupted while modem power is off, its exit trap
  attempts to restore the configured power-on value and bring `wwan` back up.

Existing client connections over the mobile link will naturally be interrupted
while APNs are tested. Other working mwan3 uplinks should remain available.

## Requirements

- vanilla OpenWrt 25.12
- `modemmanager` / `mmcli`
- `curl`
- a configured netifd ModemManager interface named `wwan`
- its data device named `wwan0`
- optional: `mwan3`
- `kmod-button-hotplug` when the hardware-button integration is enabled

The defaults match the Huasifei WH3000 Pro + Quectel RM520N-GL setup for which
this MVP was prepared. Edit `/etc/config/apn-autoconfig` for other names.

The complete button flow was tested on that hardware with a live physical SIM
change from SIMon mobile/Vodafone Germany to Kaufland Mobil/Telekom Germany.
One `BTN_0` release power-cycled the modem, resolved the newly assigned
ModemManager modem/SIM object indices, detected the changed ICCID, selected
`internet.telekom`, restored real Internet access and returned `wwan` to the
online state in mwan3.

The 0.7.0 roaming flow was validated on the same router with a lifecell Ukraine
SIM in Germany. The modem registered in roaming on Telekom Germany, selected
the live-verified `internet` APN and restored Internet access. Explicitly
blocking roaming stopped only `wwan`, returned the dedicated blocked result
without cycling APNs, and remained effective across a reboot without boot
retries. Returning the policy to its OpenWrt default restored the existing
profile without reapplying it.

## Signed package repository

OpenWrt 25.12 routers can install and upgrade all three packages from the
project's signed APK repository. Trust its public key once, add the feed and
install the LuCI package; APK resolves the core and provider-database
dependencies automatically:

```sh
wget -O /tmp/apn-autoconfig.pem \
  https://darthanwalt.github.io/openwrt-apn-autoconfig/public-key.pem
echo '0d4d6d383c84205c8fa16fafdf341ff80de24c63574a1d7d938cfb532fa458d3  /tmp/apn-autoconfig.pem' \
  | sha256sum -c -
cp /tmp/apn-autoconfig.pem /etc/apk/keys/apn-autoconfig.pem
chmod 0644 /etc/apk/keys/apn-autoconfig.pem

feed='https://darthanwalt.github.io/openwrt-apn-autoconfig/25.12/noarch/packages.adb'
grep -qxF "$feed" /etc/apk/repositories.d/customfeeds.list 2>/dev/null ||
  echo "$feed" >>/etc/apk/repositories.d/customfeeds.list

apk update
apk add luci-app-apn-autoconfig
```

The public-key SHA-256 fingerprint is:

```text
0d4d6d383c84205c8fa16fafdf341ff80de24c63574a1d7d938cfb532fa458d3
```

Normal package upgrades no longer require `--allow-untrusted`:

```sh
apk update
apk upgrade apn-autoconfig apn-autoconfig-providers luci-app-apn-autoconfig
```

To upgrade only the independently versioned provider database:

```sh
apk update
apk upgrade apn-autoconfig-providers
```

The feed is generated with the official OpenWrt 25.12 SDK APK v3 tool. Its
signed `packages.adb`, package payloads, JSON inspection output, checksums and
public key are published by the release workflow through GitHub Pages. The
private signing key is never stored in the repository or build artifacts.

## Building the APK

The package is built with the official OpenWrt 25.12.5 mediatek/filogic SDK.
On Linux x86_64:

```sh
sh scripts/build-with-sdk.sh
```

The resulting packages and checksums are written to `dist/`. On macOS, use the
included GitHub Actions workflow because the official SDK is a Linux x86_64
toolchain.

Install locally built packages on OpenWrt 25.12 in one transaction:

```sh
apk add --allow-untrusted \
  ./apn-autoconfig-providers-2026.07.16-r1.apk \
  ./apn-autoconfig-0.8.0-r1.apk \
  ./luci-app-apn-autoconfig-0.3.0-r1.apk
```

Use the same single transaction when upgrading from 0.7.0. It transfers
`/usr/share/apn-autoconfig/providers.tsv` from the old core package to the new
provider package while preserving the UCI configuration, baseline and ICCID
cache. Do not uninstall 0.7.0 first, because a real core removal intentionally
runs `reset`.

The core package owns:

```text
/usr/sbin/apn-autoconfig
/usr/libexec/apn-autoconfig-boot
/usr/libexec/apn-autoconfig-action
/usr/libexec/apn-autoconfig-query
/usr/libexec/apn-autoconfig-control
/etc/config/apn-autoconfig
/etc/init.d/apn-autoconfig
/etc/hotplug.d/button/50-apn-autoconfig
```

The provider package owns:

```text
/usr/share/apn-autoconfig/providers.tsv
```

The UCI file is declared as a package configuration file. Cache files are
created later under `/etc/apn-autoconfig/cache/`.

The LuCI package adds **Network → APN Auto-Config**. It owns only its view,
menu and ACL files and can be removed independently from the core.

## LuCI actions and operation state

The web interface provides two APN/modem actions:

- **Re-detect and verify APN** runs `reconcile`;
- **Power-cycle modem and re-read SIM** runs `modem-reset`.

It also shows home and serving networks, registration and roaming state, and a
three-state control for OpenWrt's existing roaming policy: default, explicitly
allow, or explicitly block. Version 0.3.0 also shows the active provider
database version, format, source revisions and path. It does not perform
network update checks; signed feed support is planned separately.

Both show a confirmation first. After confirmation the HTTP request only starts
a background job; it does not remain open for the full modem reset. The page
polls the machine API and disables both buttons for the entire operation. The
same busy indicator also covers a command started through SSH or the physical
button, so entry points cannot overlap. The packaged button handler submits its
reset through the same background job API, allowing LuCI to show the exact
action and its final success or failure.

Runtime job state is deliberately volatile and stored by default in:

```text
/tmp/apn-autoconfig-action/state.tsv
```

It records `starting`, `running`, `success`, `blocked`, `retryable` or `failed`; it contains no SIM
secrets beyond the action name and process/timing information. The normal APN
operation lock remains authoritative.

Machine-readable commands used by LuCI are also available for diagnostics:

```sh
apn-autoconfig status-json
apn-autoconfig detect-json
apn-autoconfig action-start reconcile
apn-autoconfig action-start modem-reset
apn-autoconfig action-status
```

The v2 status schema includes modem and registration states, separate home and
serving operators, roaming state and effective policy, manual PLMN lock,
access technologies, signal quality, a stable result code and active provider
database metadata.

The LuCI ACL does not execute the general-purpose command directly. Separate
query and control wrappers accept only the required read-only and mutating
operations.

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

Reconcile the current SIM with its cached/database APN:

```sh
apn-autoconfig reconcile
```

`reconcile` regards a changed ICCID as authoritative. It applies the mobile profile for
the new SIM even if the previous provider's APN happens to pass the Internet
test. If ICCID, configured profile and the last successfully reconciled state all
match, it verifies connectivity and exits without restarting `wwan`.

Before APN changes, `apply` and `reconcile` wait for usable home or roaming
registration. Explicitly blocked roaming, denied registration, emergency-only
service and messaging-only registration stop without cycling APN profiles. A
registration that remains pending is reported as retryable to the bounded boot
worker.

## Data roaming policy

OpenWrt's ModemManager protocol uses `network.<interface>.allow_roaming` as
the canonical persistent policy:

- option absent: allowed by the OpenWrt default;
- `option allow_roaming '1'`: explicitly allowed;
- `option allow_roaming '0'`: explicitly blocked.

Normal APN detection, reconciliation, reset and package removal only read this
option. The LuCI page exposes an explicit travel-router control which edits
only that same canonical network option under the normal operation lock.
Blocking data while already roaming stops the mobile interface. Allowing data
when the interface is down starts and reconciles it. Technical permission does
not imply that roaming is included in the tariff or free of charge.

Equivalent explicit CLI operations are:

```sh
apn-autoconfig roaming-policy-set default
apn-autoconfig roaming-policy-set allow
apn-autoconfig roaming-policy-set block
```

`default` removes the explicit option and returns to OpenWrt's current default
of allowing roaming. Direct `mmcli --simple-connect` policy changes are avoided
because netifd owns bearer creation and would replace them on reconnect.

Return to the mobile profile that existed before the first `apply`:

```sh
apn-autoconfig reset
```

`reset` restarts only `wwan`. It does not change mwan3, Travelmate, firewall,
DNS, WireGuard, ZeroTier, or any other network interface.

Logs use the tag `apn-autoconfig`:

```sh
logread | grep apn-autoconfig
```

## Hardware modem reset and button

The reset command is deliberately available before the button is enabled:

```sh
apn-autoconfig modem-reset
```

For the tested Huasifei WH3000 Pro eMMC this performs the following bounded
sequence:

1. acquire the normal APN operation lock;
2. stop only `wwan`;
3. write `1` to `/sys/class/gpio/modem_power/value` for five seconds;
4. restore the value to `0`;
5. wait up to 90 seconds for ModemManager and a readable SIM;
6. run `reconcile`, which selects and tests the APN;
7. leave `mwan3` configuration untouched.

The GPIO polarity and path are board-specific. The defaults are based only on
the WH3000 Pro eMMC sequence verified on real hardware. Do not enable this on a
different router before confirming its GPIO semantics.

After the manual command has been tested successfully, enable the physical
button explicitly:

```sh
uci set apn-autoconfig.main.button_enabled='1'
uci commit apn-autoconfig
```

The handler accepts only `BUTTON=BTN_0` with `ACTION=released`. Press events
are ignored, preventing a press/release pair from triggering two resets. The
action runs in the background so the OpenWrt hotplug dispatcher is not blocked.

Disable the button without disabling boot reconciliation:

```sh
uci set apn-autoconfig.main.button_enabled='0'
uci commit apn-autoconfig
```

Button and reset logs can be inspected with:

```sh
logread | grep -E 'apn-autoconfig(-button)?'
```

## What `apply` does

Candidate order is:

1. the APN cached for the current ICCID;
2. matching rows from the local TSV, most specific first and then by priority;
3. optionally an empty APN when `option try_empty '1'` is configured.

For each candidate the helper:

1. confirms that registration and roaming policy permit packet data;
2. writes the APN, optional credentials, authentication and IP type through
   UCI and commits `network`;
3. runs `ifdown wwan`, then `ifup wwan`;
4. waits until netifd reports the interface as up;
5. runs an HTTPS request through `wwan0` with `curl`;
6. caches a successful result by ICCID.

If every candidate fails, the original APN (including an originally absent or
empty setting) is restored and `wwan` alone is restarted.

## Configuration

Default `/etc/config/apn-autoconfig`:

```text
config apn_autoconfig 'main'
        option interface 'wwan'
        option sim_index 'auto'
        option device 'wwan0'
        option database '/usr/share/apn-autoconfig/providers.tsv'
        option cache_dir '/etc/apn-autoconfig/cache'
        option state_dir '/etc/apn-autoconfig'
        option test_url 'https://connectivitycheck.gstatic.com/generate_204'
        option wait_seconds '35'
        option registration_wait_seconds '30'
        option try_empty '0'
        option use_mwan3 'auto'
        option lock_dir '/var/lock/apn-autoconfig.lock'
        option action_state_dir '/tmp/apn-autoconfig-action'
        option autostart '0'
        option boot_delay '30'
        option boot_attempts '6'
        option retry_seconds '15'
        option button_enabled '0'
        option button_name 'BTN_0'
        option modem_power_path '/sys/class/gpio/modem_power/value'
        option modem_power_off_value '1'
        option modem_power_on_value '0'
        option modem_power_off_seconds '5'
        option modem_wait_seconds '90'
        option modem_poll_seconds '2'
```

## Optional boot reconciliation

The installed procd service does nothing by default. After manual `reconcile`
testing, enable **Automatic reconciliation at boot** in LuCI and save the
configuration. The equivalent command is:

```sh
uci set apn-autoconfig.main.autostart='1'
uci commit apn-autoconfig
```

On boot it waits `boot_delay` seconds and then runs `reconcile`. Temporary
failures are retried at most `boot_attempts` times with `retry_seconds` between
attempts. It never loops indefinitely and does not use procd respawn. Keep the
init script enabled; the `autostart` option is the authoritative behavior
switch and the boot worker exits without touching the network when it is off.

Disable it in LuCI by clearing the same checkbox, or use:

```sh
uci set apn-autoconfig.main.autostart='0'
uci commit apn-autoconfig
```

`use_mwan3` accepts `auto`, `always`, or `never`. `auto` uses `mwan3 use` only
when mwan3 exists and knows the configured interface.

The current primary SIM is resolved on every command by matching the
ModemManager device to `network.<interface>.device`. This is necessary because
ModemManager assigns new numeric modem and SIM object indices after a hardware
power cycle. A numeric `sim_index` remains supported only as a fallback for
older configurations and unusual ModemManager setups.

`try_empty` is disabled by default because an empty APN can yield a formally
connected bearer with an IP address but no return traffic. Enable it only if
you deliberately want it as the final fallback.

## Generated worldwide provider database

The separately packaged database contains Internet-capable profiles generated from two
upstream projects plus manually verified overrides. MMS-only, IMS, FOTA, XCAP,
CBS, emergency, WAP-only, disabled and test-network profiles are excluded.

Exact upstream revisions are pinned so normal OpenWrt package builds never
depend on the network. A scheduled workflow checks upstream weekly, retains
removed profiles as low-priority fallbacks, rejects suspicious changes and
commits only a fully verified generated update. See `docs/provider-database.md`
for source, filtering, licensing and regeneration details.

The schema is tab-separated:

```text
mccmnc  imsi_pattern  iccid_pattern  gid1  spn  provider  apn  priority  username  password  auth  ip_type
```

Use `-` for an unconstrained or unavailable field. `x` in an IMSI or ICCID
pattern matches one decimal digit. Plain shorter patterns match the beginning
of the SIM identifier. More specific rows win; `priority` orders equally
specific candidates.

Example:

```text
26201  -  -  01  Kaufland Mobil  Kaufland Mobil (Telekom DE)  internet.telekom  10
```

The file must contain literal TAB characters, not spaces.

The comment header records a date-based database version, the schema format and
the exact upstream source revisions. Database package versions use
`YYYY.MM.DD-rN` and are independent from the core version.

The ModemManager backend applies APN, username, password, authentication and
IP-family as one profile. Passwords are used internally and are never included
in the read-only JSON candidate API.

## Cache

Successful results are stored as one small TSV file per ICCID:

```text
/etc/apn-autoconfig/cache/<ICCID>.tsv
```

The cache is tried before the database. Remove one file to force fresh
detection for that SIM.

## Exact rollback and package removal

The first `apply` creates a persistent baseline recording the original values
and presence of all five managed UCI options. Consequently, an originally
absent option is removed again rather than restored as an empty option. A
baseline created by v0.5 is migrated on first use.

To undo testing but keep the package installed:

```sh
apn-autoconfig reset
```

To restore the baseline and remove the package:

```sh
apk del apn-autoconfig
```

The package pre-deinstall script stops and disables the boot service, then
restores the baseline. If restoration fails, removal aborts. After a successful
reset, package removal deletes:

```text
/usr/sbin/apn-autoconfig
/etc/config/apn-autoconfig
/etc/apn-autoconfig/             (baseline and cache)
```

The core removal scripts do not own or delete the provider database. APK
manages it as the separate `apn-autoconfig-providers` package. To explicitly
remove both packages, list both in the same `apk del` transaction after the
core profile reset succeeds.

Removal deliberately deletes this package's modified UCI configuration instead
of leaving a package-manager configuration remnant. It does not modify mwan3,
Travelmate, firewall, DNS, WireGuard, ZeroTier or any unrelated interface.

Package removal also removes the button handler. It does not leave a hotplug
script or enable any APN automation outside this package.

## Attended sysupgrade

This package is not yet in an official OpenWrt feed. A local `.apk` is therefore
not guaranteed to be included by the public Attended Sysupgrade server. Do not
assume seamless ASU preservation until a custom signed feed or an official feed
submission has been implemented and tested.

## Known limitations

- Worldwide coverage is broad but cannot be mathematically complete: carrier
  settings change and some MVNOs do not expose a usable SIM discriminator.
- Automatic SIM resolution requires ModemManager to expose a primary SIM path;
  a configured numeric `sim_index` is used only when resolution is impossible.
- The connectivity test uses HTTPS through one configured net device. It uses
  the profile's IPv4 or IPv6 family and tries both for dual-stack profiles.
- Boot and hardware-button automation are independently opt-in and exposed as
  separate LuCI checkboxes.
- The bundled GPIO defaults are specific to the tested Huasifei WH3000 Pro
  eMMC and must not be assumed correct for another board.
- A missing or stale provider profile requires a manually verified override
  and regeneration of the database.
- ModemManager cannot report tariff cost, roaming quotas or whether roaming is
  free. The policy controls technical permission only.
- A generic bearer rejection cannot always distinguish a wrong APN from a
  subscription or roaming-agreement restriction; messages avoid claiming an
  APN-specific cause without evidence.

The database is designed to improve continuously without making router package
builds or runtime behavior depend on upstream availability.
