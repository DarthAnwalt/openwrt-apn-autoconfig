# apn-autoconfig — OpenWrt source packages

`apn-autoconfig` is a target-aware POSIX-shell APN engine for OpenWrt. The
0.9.1 alpha discovers configured cellular netifd interfaces and publishes both
their runtime capabilities and validation level through a GUI-independent API.
Its operational backends are ModemManager and native OpenWrt QMI. QMI identity
uses `uqmi` with a same-USB-device AT fallback through `sms-tool`; profile
application is delegated to the configured netifd `qmi.sh` target. MBIM, Fibocom and
selected AT-managed protocols remain inventory-only. The engine resolves the active SIM, finds mobile profile
candidates in a worldwide local TSV database, restarts only the selected mobile
interface, verifies real Internet access through netifd's current layer-3 device, caches
the successful profile by ICCID, and restores the previous profile when all candidates
fail. It distinguishes the SIM's home operator from the serving network,
honors OpenWrt's canonical data-roaming policy before changing any APN, and
reports registration failures separately from profile failures. It includes an idempotent `reconcile` command for SIM transitions and an
opt-in delayed boot service. A separately installed Huasifei board integration
can power-cycle the modem through its verified exported GPIO and reconcile the
APN after the modem returns. Boot automation is disabled by default; physical
controls are not treated as a generic router capability.

This repository contains four OpenWrt packages. It builds normal `.apk`
packages with the official OpenWrt 25.12 SDK:

- `apn-autoconfig`, the POSIX-shell core;
- `apn-autoconfig-providers`, the independently versioned provider database;
- `luci-app-apn-autoconfig`, the optional web interface;
- `apn-autoconfig-integration-huasifei-wh3000`, the optional, board-specific
  BTN_0/GPIO integration tested on the Huasifei WH3000 Pro.

The generated provider database combines GNOME mobile-broadband-provider-info,
the AOSP sample APN database and locally verified overrides. Large upstream XML
files are converted at development time into a compact TSV installed on the
router.

The implementation is MIT licensed. Imported AOSP data is Apache-2.0 and the
GNOME provider database carries the Creative Commons Public Domain Dedication
and Certification (CC-PDDC). This is a multi-license repository: see `LICENSE`,
`LICENSING.md`, `THIRD_PARTY_NOTICES.md` and `data/licenses/` for the exact
scope, attribution and terms. References to upstream projects and mobile
operators are factual and do not imply affiliation, sponsorship or endorsement.

## Safety model

- `detect` and `status` are read-only.
- Normal APN operations never write `network.<interface>.allow_roaming`; the
  existing OpenWrt network option remains the sole source of roaming policy.
- `apply` edits only the selected backend's owned profile options under
  `network.<interface>`: `apn`, `username`, `password`, `allowedauth`, `iptype`
  for ModemManager, or `apn`, `username`, `password`, `auth`, `pdptype` for QMI.
- It calls only `ifdown <selected-target>` / `ifup <selected-target>`; it does not reload or restart the
  whole network.
- It does not edit mwan3 interfaces, members, policies, rules, or metrics.
- If mwan3 is available, the connectivity test is run using
  `mwan3 use wwan curl ...` so the test follows the selected WAN routing table.
- An interrupted or failed `apply` restores the prior mobile profile and restarts only
  the selected target.
- Before the first `apply`, the original profile state is stored persistently in
  `/etc/apn-autoconfig/targets/network_<interface>/baseline.tsv`.
- Baseline, active-profile and ICCID-cache files may contain APN usernames and
  passwords in cleartext. This is intentional, matches OpenWrt's `network` UCI
  storage, and is restricted to root by the process-wide `umask 077`.
- `reset` restores that pre-test profile state and removes generated cache.
- `apk del apn-autoconfig` runs `reset` before deleting any files. If reset
  fails, package removal is aborted and the program remains available for
  diagnosis and retry.
- A lock prevents two simultaneous `apply` runs.
- The boot service is installed but inert while `option autostart '0'` remains
  configured.
- The core installs no physical-button handler. The optional Huasifei package
  installs one, and it remains inert while `option button_enabled '0'` is set.
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
- `sms-tool`, installed automatically as the common read-only AT transport
- `modemmanager` / `mmcli` for the stable write/apply backend; it is no longer
  pulled into GUI-independent core installations automatically
- `uqmi` for a configured QMI target; it is normally supplied with OpenWrt's
  QMI protocol support and is not pulled into unrelated core installations
- `curl`
- at least one configured netifd ModemManager or QMI interface; its name is
  discovered automatically when it is the only writable cellular target
- optional: `mwan3`
- optional `apn-autoconfig-integration-huasifei-wh3000`, which pulls
  `kmod-button-hotplug`, only for the tested Huasifei button/GPIO flow

`option device 'wwan0'` is only a fallback for systems whose netifd status does
not expose `l3_device`. The hardware-reset GPIO defaults still match only the
Huasifei WH3000 Pro + Quectel RM520N-GL setup for which the MVP was prepared.
For QMI identity, the control channel is taken from the selected
target's `/dev/cdc-wdm*`/`/dev/wwan*qmi*` `device`, or from exactly one safe
match below its official OpenWrt `devpath`; this is separate from the layer-3
data device used for connectivity checks.

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

OpenWrt 25.12 routers can install and upgrade the core, database, LuCI and
optional Huasifei integration packages from the
project's signed APK repository.

### Quick installer

The convenience installer checks the OpenWrt release, verifies the pinned
repository key and signed APK indexes, simulates the selected installation and
then configures the feed. It asks whether to install the LuCI web interface:

```sh
wget -qO- https://darthanwalt.github.io/openwrt-apn-autoconfig/install.sh | sh
```

The default answer installs LuCI together with the core and provider database.
Answer `n` for a command-line-only installation. For non-interactive use, make
the choice explicit:

```sh
# Core, provider database and LuCI
wget -qO- https://darthanwalt.github.io/openwrt-apn-autoconfig/install.sh | sh -s -- --gui

# Core and provider database only
wget -qO- https://darthanwalt.github.io/openwrt-apn-autoconfig/install.sh | sh -s -- --nogui
```

To verify compatibility and preview APK's transaction without changing
persistent files, add `--dry-run`:

```sh
wget -qO- https://darthanwalt.github.io/openwrt-apn-autoconfig/install.sh | sh -s -- --dry-run
```

> [!WARNING]
> Piping a remote script directly into a root shell is convenient, but it means
> trusting the HTTPS endpoint and executing the received contents without
> reviewing them first. `--dry-run` prevents persistent installer changes; it
> does not make an unreviewed remote script intrinsically trustworthy. Use the
> download-and-review procedure below or the manual commands if this trust
> model is not acceptable.

A more cautious installation downloads the script first, verifies its
published checksum, allows it to be reviewed, and only then runs it:

```sh
wget -O /tmp/install.sh \
  https://darthanwalt.github.io/openwrt-apn-autoconfig/install.sh
wget -O /tmp/apn-autoconfig-SHA256SUMS \
  https://darthanwalt.github.io/openwrt-apn-autoconfig/SHA256SUMS
(cd /tmp && grep '  install.sh$' apn-autoconfig-SHA256SUMS >install.sha256)
test -s /tmp/install.sha256
(cd /tmp && sha256sum -c install.sha256)
sed -n '1,260p' /tmp/install.sh
sh /tmp/install.sh --dry-run
sh /tmp/install.sh
rm -f /tmp/install.sh /tmp/install.sha256 /tmp/apn-autoconfig-SHA256SUMS
```

Both modes leave automatic APN reconciliation disabled and do not install a
physical-button integration. After installation, enable automation deliberately.
Package upgrades should use LuCI or `apk`; there is no advantage
to downloading and rerunning the bootstrap installer.

### Manual repository setup

To avoid running an installer, trust the public key once, add the feed and
install either the LuCI package or the command-line core. APK resolves the
provider-database dependency automatically:

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

For a command-line-only installation, use this final command instead:

```sh
apk add apn-autoconfig
```

Only on the tested Huasifei WH3000 Pro, install the separate board adapter if
the BTN_0/GPIO modem-reset flow is desired:

```sh
apk add apn-autoconfig-integration-huasifei-wh3000
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

Packages originally installed from local `.apk` files may have checksum-bound
entries in `/etc/apk/world`. In that one-time migration case, `apk` can list a
newer signed-feed package as upgradable while a normal `apk upgrade` makes no
change. After adding the signed repository and running `apk update`, replace
those local-file constraints with normal package names, then upgrade:

```sh
apk add apn-autoconfig apn-autoconfig-providers luci-app-apn-autoconfig
apk upgrade apn-autoconfig apn-autoconfig-providers luci-app-apn-autoconfig
```

The first command only normalizes the world constraints when the same versions
are already installed. Subsequent upgrades use the normal `apk upgrade` command.

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
  ./apn-autoconfig-providers-2026.07.18-r1.apk \
  ./apn-autoconfig-0.9.1_alpha1-r4.apk \
  ./luci-app-apn-autoconfig-0.6.0_alpha1-r5.apk
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
/usr/libexec/apn-autoconfig-database
/usr/libexec/apn-autoconfig-qmi
/etc/config/apn-autoconfig
/etc/init.d/apn-autoconfig
```

The provider package owns:

```text
/usr/share/apn-autoconfig/providers.tsv
```

The UCI file is declared as a package configuration file. Cache files are
created later under `/etc/apn-autoconfig/cache/`.

The LuCI package adds **Network → APN Auto-Config**. It owns only its view,
menu and ACL files and can be removed independently from the core.

The optional Huasifei integration owns only:

```text
/etc/hotplug.d/button/50-apn-autoconfig
/usr/share/apn-autoconfig/integrations/huasifei-wh3000
/usr/share/licenses/apn-autoconfig-integration-huasifei-wh3000/LICENSE
```

## LuCI actions and operation state

The web interface always provides the backend-supported APN action:

- **Re-detect and verify APN** runs `reconcile`;
- **Power-cycle WH3000 modem and re-read SIM** appears only when the separate
  Huasifei board integration is installed and runs the guarded `modem-reset`.

It groups mobile registration and signal, the current APN, provider-database
state, roaming policy and actions into separate responsive sections. Technical
SIM identifiers and database source revisions remain available in collapsible
details. Signal quality uses LuCI's native progress visualization and keeps the
numeric percentage visible.

The provider-database section shows the installed package and data versions,
data release date, last check, available version, configured feed and trusted
key. **Check for updates** refreshes only the configured project repository.
When a newer database exists, **Install update** confirms and upgrades only
`apn-autoconfig-providers`; it does not upgrade the core or LuCI, change the
active APN, or restart the mobile interface. The candidate package is fetched
through APK's signed index and its TSV metadata and rows are validated before
installation.

Version 0.6.0_alpha1 retains the policy-selection fix: the Apply button remains
disabled until the user deliberately changes the selection.

Both show a confirmation first. After confirmation the HTTP request only starts
a background job; it does not remain open for the full modem reset. The page
polls the machine API and disables both buttons for the entire operation. The
same busy indicator also covers a command started through SSH or the physical
button, so entry points cannot overlap. The packaged button handler submits its
reset through the same background job API, allowing LuCI to show the exact
action and its final success or failure. Database checks and installations use
the same dispatcher and lock, so the provider file cannot be replaced while an
APN operation is reading it.

Runtime job state is deliberately volatile and stored by default in:

```text
/tmp/apn-autoconfig-action/state.tsv
```

It records `starting`, `running`, `success`, `blocked`, `retryable` or `failed`
and the stable target ID; it contains no SIM secrets beyond the action name and
process/timing information. The normal APN
operation lock remains authoritative.

The most recent database check and installation result survives reboot in:

```text
/etc/apn-autoconfig/database-update.tsv
```

It contains package versions, timestamps and a sanitized result message, but no
SIM identifiers, APNs or credentials.

Machine-readable commands used by LuCI are also available for diagnostics:

```sh
apn-autoconfig status-json
apn-autoconfig detect-json
apn-autoconfig targets-json
apn-autoconfig action-start reconcile
apn-autoconfig action-start modem-reset
apn-autoconfig action-start database-check
apn-autoconfig action-start database-install
apn-autoconfig action-status
```

The v2 target schema reports each stable target ID, protocol, normalized
backend, exact read/write/apply capabilities and separate implementation,
validation and hardware-evidence states. The v2 status schema remains
backward compatible and adds `engine_api: v1`, target/backend fields and the
effective layer-3 device. It includes modem and registration states, separate home and
serving operators, roaming state and effective policy, manual PLMN lock,
access technologies, signal quality, a stable result code and active provider
database metadata.

The LuCI ACL does not execute the general-purpose command directly. Separate
query and control wrappers accept only the required read-only and mutating
operations. Both wrappers accept an optional validated `network:<section>`
target; the background worker preserves it for the complete operation.

## First use

Start with the read-only command:

```sh
apn-autoconfig targets-json
apn-autoconfig detect
```

`targets-json` is the authoritative way to distinguish discovery from actual
support. ModemManager and QMI targets report `profile_apply: true` only when
their required runtime commands are available. This alpha reports the QMI
implementation and hardware evidence separately from its runtime capability.
Use `--target network:<section>` with status, detect or mutating commands when
more than one writable target is configured.

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

`reset` restarts only its selected target. It does not change mwan3, Travelmate, firewall,
DNS, WireGuard, ZeroTier, or any other network interface.

Logs use the tag `apn-autoconfig`:

```sh
logread | grep apn-autoconfig
```

## Optional Huasifei hardware modem reset and button

This is not a generic router-button feature. Install the separately packaged
integration only on the tested Huasifei WH3000 Pro:

```sh
apk add apn-autoconfig-integration-huasifei-wh3000
```

The integration installs `kmod-button-hotplug`, a BTN_0 hotplug adapter and a
marker that unlocks the guarded reset command and the corresponding LuCI
controls. Without it, `modem-reset` exits with target-contract code 4 before
touching GPIO or the network. After installation, test the manual command:

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

The packaged handler accepts only `BUTTON=BTN_0` with `ACTION=released`. Press events
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
3. runs `ifdown` and `ifup` only for the selected target;
4. waits until netifd reports the interface as up;
5. asks netifd for the current `l3_device` and runs an HTTPS request through it
   with `curl` (falling back to configured `option device` only when absent);
6. caches a successful result by ICCID.

If every candidate fails, the original APN (including an originally absent or
empty setting) is restored and only the selected target is restarted.

## Configuration

Default `/etc/config/apn-autoconfig`:

```text
config apn_autoconfig 'main'
        option interface 'auto'
        option sim_index 'auto'
        option device 'wwan0'
        option database '/usr/share/apn-autoconfig/providers.tsv'
        option database_feed 'https://darthanwalt.github.io/openwrt-apn-autoconfig/25.12/noarch/packages.adb'
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

`interface` accepts `auto` or a UCI network section name. Automatic mode selects
only when exactly one discovered target has a complete write/apply backend. It
does not guess between two eligible modems. Existing upgrades retain their
explicit conffile value (for example `wwan`).

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

The first `apply` for each target creates a persistent baseline recording the original values
and presence of all five managed UCI options. Consequently, an originally
absent option is removed again rather than restored as an empty option. A
baseline created by v0.5–0.8 is migrated under the operation lock on first use.
Target baselines and active state live below
`/etc/apn-autoconfig/targets/network_<interface>/`; the per-ICCID profile cache
remains shared because it belongs to the SIM rather than an interface.

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

Removing the core does not remove or rewrite files owned by the optional board
integration. Removing `apn-autoconfig-integration-huasifei-wh3000` removes its
button handler and marker; APK also prevents leaving it installed without its
core dependency. Neither package enables button handling in UCI by default.

## Attended sysupgrade

This package is not yet in an official OpenWrt feed. A local `.apk` is therefore
not guaranteed to be included by the public Attended Sysupgrade server. Do not
assume seamless ASU preservation until a custom signed feed or an official feed
submission has been implemented and tested.

## Known limitations

- Worldwide coverage is broad but cannot be mathematically complete: carrier
  settings change and some MVNOs do not expose a usable SIM discriminator.
- ModemManager SIM resolution requires a primary SIM path; a configured numeric
  `sim_index` is used only when resolution is impossible. QMI currently targets
  the primary SIM exposed by its control channel.
- The reference RM520N rejects native `uqmi` ICCID/IMSI calls, so QMI identity
  uses the strictly same-device AT fallback. Packaged QMI apply, failure,
  reboot and soak gates must pass before the alpha becomes stable.
- MBIM, Fibocom and AT-managed profile operations remain unavailable; mutating
  commands for those targets exit 4 before changing UCI, state or interfaces.
- The connectivity test uses HTTPS through netifd's effective layer-3 device. It uses
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
