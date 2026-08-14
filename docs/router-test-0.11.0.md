# 0.11.0 WH3000 provisioning hardware record

Date: 2026-08-15
Status: exploratory validation of the provisioning path. **Not a release gate.**
0.11.0 is incomplete — the manual APN path, the LuCI first-run view and the
lifecycle tests do not exist yet — so nothing here justifies a stable claim.

## Method

The router has one modem, already configured as the ModemManager target `wwan`
and serving as the backup uplink behind a WiFi primary. Provisioning refuses a
modem that is already bound, so the modem had to be freed first.

Nothing was installed. The 0.11.0 `apn-autoconfig-modem` was staged in `/tmp`
and executed from there, with its SHA-256 matched against the local build; the
installed 0.10.1 packages stayed untouched throughout (`apk audit` reported no
modified project file at the start and at the end). The installed 0.10.1 engine
already accepts the borrowed operation lock, so no core change was needed.

### Freeing the modem without dismantling anything

`wwan` was **parked, not deleted**: `ifdown`, `disabled=1`, and its `device`
repointed at a path that matches nothing. The section, its APN, metric,
multipath and loglevel options, the `mwan3` membership referring to it and the
engine's `network_wwan` state all stayed in place. Deleting the section would
have made `mwan3` rebuild rules for every member; a section that is merely down
is a state `mwan3` handles routinely.

Note that `disabled=1` alone is not enough to free a modem: inventory treats a
disabled user section as still claiming the device. Repointing `device` is what
makes the modem appear unconfigured.

### Recovery proven before it was needed

A restore script was generated from the live `wwan` values rather than written
by hand, and it removes only sections carrying the project ownership marker. A
detached watchdog restores from a deadline file, independent of the SSH session.

Recovery was rehearsed **before** the real run: `wwan` was parked, the watchdog
armed for 90 s, and nothing was provisioned. The router restored itself
autonomously — device, `disabled`, the `BTN_0` setting, interface up and real
connectivity — and the watchdog exited. Only then was the actual test run.

The control channel is LAN (`br-lan`), independent of both uplinks, so no
failure of the modem or the WiFi primary could have prevented manual recovery.

## Results

**Refusal paths, with no configuration change at all.** Against the live
production modem, `provision-plan` returned `already_configured` and exit 4;
`deprovision` and `connect` both returned exit 4. `uci show network` was
byte-identical before and after, with zero uncommitted changes.

**Provisioning.** With the modem freed, `provision-plan` reported
`can_provision: true`, section `apnmodem1`, protocol `modemmanager`.
`provision` completed in 10 s, exit 0. The engine registered on the home
network, found no reconciled state for the new target, saved the original
profile as its baseline, ran APN detection from the database and confirmed
`web.vodafone.de` working. Because the new target had no prior state, this
exercised fresh database matching rather than the cached path.

The created section carried all three ownership markers, `proto=modemmanager`,
the real USB device path, and the `apn` written by the **engine** — provisioning
never wrote a profile field itself. `disabled` was cleared and `auto` absent
after promotion. netifd reported the interface up on `wwan0`, and a real HTTPS
request over it succeeded. Both operation locks were clear.

**Provisioning never started the section itself.** The log line
`started interface apnmodem1 once to obtain mobile registration state` comes
from the engine. This was a defect found while preparing this run: provisioning
used to call `ifup` after clearing `disabled` and before reconciliation, which
would have handed netifd a cellular section with no `apn`. The fixtures could
not see it because the mocked `ifup` is inert.

**Automatic target selection stayed unambiguous.** With `apnmodem1` marked and
disabled and the engine set to `auto`, selection resolved to `network:wwan` and
exited 0. Without the exclusion this is precisely the
`multiple writable cellular targets found` failure, so a second provisioned
modem would have broken APN operations on a working one.

**Teardown.** `deprovision` removed the section and its provisioning baseline,
exit 0, leaving no project-owned section. The restore script then returned
`wwan` to its captured values; the final `uci show network.wwan` matches the
pre-test capture exactly, `BTN_0` is enabled again, there are no uncommitted
changes, the interface is up with verified connectivity, and no lock or test
artefact remains.

## Defects and gaps this run exposed

1. **Fixed before the run:** provisioning started the staging section before the
   engine had chosen a profile. See above.

2. **Fixed after the run, re-verified on hardware — orphaned engine state.**
   As first run, `deprovision` removed the section and the
   provisioning baseline, but the APN engine's per-target state survived:
   `/etc/apn-autoconfig/targets/network_apnmodem1/{baseline,active}.tsv`
   remained, recording the original profile and the applied APN with its ICCID.
   It accumulates across provision/deprovision cycles, and a later provisioning
   that reuses the section name would meet state belonging to a different SIM.
   It was removed by hand here.

   The obvious fix — having `deprovision` call
   `apn-autoconfig reset --target network:<section>` — is **not safe**: when a
   target has no baseline, `reset_cmd` executes `rm -rf "$CACHE_DIR"`, and that
   cache is shared across targets, so a per-target reset would wipe the SIM
   cache for every target.

   The engine instead gained `forget-target`, which drops exactly one target's
   state, refuses while a section of that name still exists, and leaves the
   shared cache and other targets untouched. `deprovision` now calls it and
   reports `engine_state`.

   Re-verified on this router afterwards: a full provision/deprovision cycle
   returned `engine_state: dropped`, `/etc/apn-autoconfig/targets/` was left
   holding only `network_wwan`, and the shared cache kept all three entries.
   `wwan` was restored with verified connectivity, and no test artefact,
   watchdog or modified package file remained.

## Not covered

Interruption of provisioning on hardware, two simultaneous provisioning
attempts on hardware, `connect`/`disconnect`/`reconnect` on hardware, and any
lifecycle testing of a 0.11.0 package — none was built or installed. All of
those are covered by fixtures only.
