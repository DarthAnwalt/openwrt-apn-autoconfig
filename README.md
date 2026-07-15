# apn-autoconfig 0.5.0 — OpenWrt source packages

`apn-autoconfig` is a small POSIX-shell helper for a ModemManager interface on
OpenWrt. It dynamically resolves the active ModemManager SIM, finds APN
candidates in a local TSV database, restarts only the configured mobile
interface, verifies real Internet access through `wwan0` with `curl`, caches
the successful APN by ICCID, and restores the previous APN when all candidates
fail. It includes an idempotent `reconcile` command for SIM transitions and an
opt-in delayed boot service. It can also power-cycle a modem through an
exported GPIO and reconcile
the APN after the modem returns. Boot and hardware-button automation are both
disabled by default.

This repository contains two OpenWrt source packages. It builds normal `.apk`
packages with the official OpenWrt 25.12 SDK:

- `apn-autoconfig`, the POSIX-shell core;
- `luci-app-apn-autoconfig`, the optional web interface.

It is still an MVP and does not yet include a finished worldwide provider
database.

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
apk add --allow-untrusted ./apn-autoconfig-0.5.0-r1.apk
apk add --allow-untrusted ./luci-app-apn-autoconfig-0.1.0-r1.apk
```

The package owns:

```text
/usr/sbin/apn-autoconfig
/usr/libexec/apn-autoconfig-boot
/usr/libexec/apn-autoconfig-action
/usr/libexec/apn-autoconfig-query
/usr/libexec/apn-autoconfig-control
/usr/share/apn-autoconfig/providers.tsv
/etc/config/apn-autoconfig
/etc/init.d/apn-autoconfig
/etc/hotplug.d/button/50-apn-autoconfig
```

The UCI file is declared as a package configuration file. Cache files are
created later under `/etc/apn-autoconfig/cache/`.

The LuCI package adds **Network → APN Auto-Config**. It owns only its view,
menu and ACL files and can be removed independently from the core.

## LuCI actions and operation state

The web interface provides two actions:

- **Re-detect and verify APN** runs `reconcile`;
- **Power-cycle modem and re-read SIM** runs `modem-reset`.

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

It records `starting`, `running`, `success` or `failed`; it contains no SIM
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

`reconcile` regards a changed ICCID as authoritative. It applies the APN for
the new SIM even if the previous provider's APN happens to pass the Internet
test. If ICCID, configured APN and the last successfully reconciled state all
match, it verifies connectivity and exits without restarting `wwan`.

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
        option sim_index 'auto'
        option device 'wwan0'
        option database '/usr/share/apn-autoconfig/providers.tsv'
        option cache_dir '/etc/apn-autoconfig/cache'
        option state_dir '/etc/apn-autoconfig'
        option test_url 'https://connectivitycheck.gstatic.com/generate_204'
        option wait_seconds '35'
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

The installed procd service does nothing by default. After manual
`reconcile` testing, enable it explicitly:

```sh
uci set apn-autoconfig.main.autostart='1'
uci commit apn-autoconfig
/etc/init.d/apn-autoconfig enable
/etc/init.d/apn-autoconfig restart
```

On boot it waits `boot_delay` seconds and then runs `reconcile`. Temporary
failures are retried at most `boot_attempts` times with `retry_seconds` between
attempts. It never loops indefinitely and does not use procd respawn.

Disable it without uninstalling the package:

```sh
uci set apn-autoconfig.main.autostart='0'
uci commit apn-autoconfig
/etc/init.d/apn-autoconfig stop
/etc/init.d/apn-autoconfig disable
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

The package pre-deinstall script stops and disables the boot service, then
restores the baseline. If restoration fails, removal aborts. After a successful
reset, package removal deletes:

```text
/usr/sbin/apn-autoconfig
/usr/share/apn-autoconfig/providers.tsv
/etc/config/apn-autoconfig
/etc/apn-autoconfig/             (baseline and cache)
```

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

- The bundled database is deliberately tiny.
- Automatic SIM resolution requires ModemManager to expose a primary SIM path;
  a configured numeric `sim_index` is used only when resolution is impossible.
- Only the APN is applied; APN username/password/authentication are not.
- The connectivity test is IPv4 HTTPS through one configured net device.
- Boot and hardware-button automation are independently opt-in. The first LuCI
  UI covers live state, manual background actions and the most relevant UCI
  settings; it does not yet manage the init-script enable/disable state.
- The bundled GPIO defaults are specific to the tested Huasifei WH3000 Pro
  eMMC and must not be assumed correct for another board.
- A provider missing from the TSV requires a manual APN or a larger generated
  database.

These limits are intentional for a first version whose failure mode is safe and
understandable.
