# 0.12.0 WH3000 package, upgrade and native MBIM validation

Date: 2026-08-16
Status: complete for everything that can be proven before publication. The
native MBIM path passed on hardware from discovery through post-connect
verification and rollback, so MBIM is `implementation_state: stable`,
`validation_state: hardware`. The signed-feed smoke remains, because it requires
the release to be published first.

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

## Native MBIM run

The module was switched to its MBIM composition through the audited sequence in
[`testing-0.12.0.md`](testing-0.12.0.md), with BTN_0 disabled, ModemManager
stopped and the production interface parked first. A restore script generated
from the live values was rehearsed before the first mutation and left the
configuration byte-identical when run in its config-only mode.

The switch behaved exactly as the audit predicted. All four serial ports came
back and `cdc_mbim` bound the new control and data interfaces, so the AT path —
the way back — was never at risk. The product id and serial did not change, so
the modem kept its stable identity across the composition change: inventory
reported the *same* `modem_id` with its original `first_seen`, now with
`protocol=mbim`.

What passed, in order:

- inventory classified the modem as MBIM with `owner_state=none` once
  ModemManager was stopped, and `provision-plan` answered `can_provision` with
  the MBIM protocol and the control device;
- the identity adapter read the real modem correctly. MBIM supplies a genuine
  home PLMN, which QMI cannot, so the operator came straight from the module
  rather than from an IMSI prefix;
- **`signal_quality` came back empty, and that is the correct answer.** This
  firmware reports `rssi: 0063` — 99, the MBIM value for "unknown" — in the home
  provider response. The contract's decision to treat 0 and 99 as unknown rather
  than as -113 dBm is what kept this honest;
- `provision` created the staging section, the APN engine selected the operator
  profile from the database, wrote it, brought the bearer up and verified real
  Internet access. The verification was re-run by hand bound to the modem's own
  interface and returned HTTP 200 from the carrier-assigned address, so the
  result is the modem path and not the WiFi uplink the router also has;
- roaming policy in all three states, with the option pair written and read back
  exactly, and `default` correctly reported as **blocked** for MBIM where
  ModemManager's default is allowed. A deliberately mixed pair read back as
  `invalid` and was left untouched;
- `disconnect` / `reconnect`, each ending in a verified bearer;
- a wrong APN failed within its bound, restored the exact previous profile and
  reported the failure class; a real `TERM` during the destructive window did
  the same and left no lock behind;
- `deprovision` removed the section and dropped that target's engine state while
  the production target's state stayed untouched;
- the restore returned the QMI composition, ModemManager, the production
  interface and the button, with `network.wwan` byte-identical to the snapshot,
  no leftover sections, no pending UCI changes and the production modem
  connected again.

## Two defects the run found

Neither could have been caught by fixtures, because both are about how the
system behaves next to a real, already-working router.

**The board power-cycle was gated on the control protocol.** `capabilities.reset`
turned false the moment the same pinned modem ran MBIM, because the check
required `protocol = qmi`. The GPIO cuts power to the slot: that is a property
of the board and the physical modem, not of the protocol, so the validated BTN_0
path silently disappeared in MBIM. Fixed to accept either proven native
protocol, with every other condition — the explicit strong pin, the board
marker, a writable GPIO, no ambiguity, no conflicting owner — unchanged.
Protocol alone still never implies reset. The button itself was not re-tested in
MBIM composition, so that specific combination remains synthetic.

**A provisioned modem took the default route.** Provisioning wrote no `metric`,
so netifd installed the section's default route at metric 0 — ahead of the
router's existing WiFi uplink at 100. Every packet the router originated,
including a tunnel daemon's, moved onto metered cellular data without anyone
asking. The behaviour is inherited from 0.11.0 and had simply never been looked
at on a router that already had an uplink. A provisioned section now carries a
conservative `provision_metric`, defaulting to 1024 in code as well as in the
shipped config, so an upgraded installation gets it too; with no other uplink
the modem still becomes the default route.

## The packages that were tested are the packages that ship

The two fixes above were built and installed on the router before this record
was closed, so the validated binaries are the ones the release publishes. The
reinstall demonstrated the conffile rule again from the other side: the new
`provision_metric` option arrived as `.apk-new` and the live configuration kept
its existing file, so the option is **absent** on this installation and the
compiled-in default is what applies. That is exactly why the default was put in
code rather than only in the shipped config.

The production QMI modem still reports `reset: true` after the capability change,
`wwan` is up, the modem path answers, and no operation lock or pending UCI
change was left behind.

## A third, smaller finding, not fixed here

`last_result` is stored once per installation rather than once per target. The
deliberately failed APN test on the MBIM section therefore showed up in the
production target's status afterwards, describing a failure that had nothing to
do with it. Everything else in that response is per-target. The stale value was
cleared so the router's status is truthful again, but the scoping itself is a
pre-existing wart from the single-target era and is left for a later release
rather than widened into this one.

## The browser gate, and the two things it found

Opening the page in a real browser earned its place again. Neither finding was
visible to any fixture, and both came from the first question a person asked
while looking at the modem card.

**The card described a validated implementation as experimental.**
`implementation_state` and `validation_state` were string constants written in
0.10.0 and never revisited, while the same code went through four hardware gates
and three releases. Maturity now describes the implementation — one code path,
so one value — and evidence describes the classified protocol: `hardware` for
QMI and MBIM, `synthetic` for AT-only and unclassified devices. The rule that
these fields stay separate also requires them to stay current; a stale
`experimental` understates a validated implementation exactly as badly as an
unearned `stable` overstates one.

**A modem with no controls did not say why.** That a modem bound to a
user-created interface offers no connect, disconnect or removal is correct: this
package does not adopt or drive interfaces it did not create. But the
explanation lived in the setup card, while the inventory card — which looks
exactly like the place controls belong — said nothing. It now names the owning
interface and states that it only reports that modem. Both directions are
asserted, so a modem that can be set up, or one this package owns, is never
described as merely reported.

Both fixes were built by the SDK and installed on the router, which then
reported `stable` / `hardware` for the production modem with its pin, button
setting and `wwan` untouched.

## Signed-feed smoke

Run after `v0.12.0` published. `apk update` picked the release up from the
signed feed, and all four packages were removed and reinstalled **without
`--allow-untrusted`** — the pinned key alone was enough, which is the property
this project refuses to compromise on.

Removal behaved as designed and as the 0.11.0 lifecycle tests assert: the
pre-deinstall hook restored the target's original mobile profile and removed the
cache and baseline, and each package took its own configuration with it. On a
production router that means the tuned values — the selected interface, the
enabled button and the pinned `reset_modem_id` — are gone after a full removal,
so they were restored from the recovery point captured before the release work.
Both configuration files and `network.wwan` are byte-identical to that snapshot
again, the modem path answers, and no lock or pending UCI change was left
behind.

Worth stating plainly for the next release: a full `apk del` is not a
configuration-preserving operation, and a router that matters should have a
recovery point before one. An upgrade in place, which is the normal path, keeps
everything.
