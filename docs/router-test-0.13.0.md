# 0.13.0 WH3000 frontend and bearer-control validation

Date: 2026-08-16
Status: complete for everything that can be proven before publication. The
reorganized page and the corrected bearer-control rule both ran on hardware
against the maintainer's production modem. The signed-feed smoke remains,
because it requires the release to be published first, and the legibility
judgement remains, because it is the maintainer's and not a fixture's.

## Environment

- OpenWrt 25.12.5 r33051-f5dae5ece4 on the Huasifei WH3000 Pro eMMC, apk 3.x;
- internal Quectel RM520N-GL in its QMI composition, owned by ModemManager,
  bound to the **user-created** netifd interface `wwan`, APN unchanged
  throughout;
- the router's primary uplink is WiFi and the modem is the backup path, so an
  administrative session surviving is never by itself evidence — every result
  below was confirmed through the modem's own layer-3 device;
- packages built by GitHub Actions from PR 33 with the official OpenWrt 25.12.5
  SDK, installed from checksum-verified local artifacts;
- recovery point captured before the first mutation and stored beside the
  earlier ones on the persistent partition;
- modem and SIM identifiers intentionally omitted from this record.

## SDK gate

The official SDK build passed on the first run, including the APK inspection
that checks each produced package against an exact expected file list and count.
This release adds no packaged file — it edits existing ones — so the expectation
was unchanged, which is exactly why the count check produced no noise.

The same run executed the Node-based LuCI regression suites, which the local
macOS gate skips for lack of a Node runtime. That gap is worth stating plainly:
`sh scripts/verify.sh` silently skips the two LuCI suites when `node` is absent,
so a developer machine without it cannot prove the frontend. CI is the
authoritative run for those.

## Live upgrade

All five package checksums were verified on the router before installation.
`apk add` upgraded `apn-autoconfig`, `apn-autoconfig-modem`, the Huasifei
integration and `luci-app-apn-autoconfig` from 0.12.0 to 0.13.0 in one
transaction, with the provider database unchanged at its date version.

Configuration survived: the selected interface, the enabled `BTN_0` and the
pinned `reset_modem_id` are all unchanged, and `wwan` stayed up across the
upgrade. Both configuration files were preserved as conffiles with `.apk-new`
written beside them, repeating the 0.11.0 and 0.12.0 finding: **a new
configuration default does not reach an existing installation.**

No packaging hook, file list or dependency changed in this release, so removal
and offline-install behaviour is the behaviour validated for 0.12.0. The
executable hook tests in `tests/test-package-lifecycle.sh` — offline image-root
install, live install, removal — ran green as part of the gate. A destructive
`apk del` rehearsal was deliberately **not** repeated on the production router:
it is known not to preserve configuration, and nothing in this release changes
the code path it would exercise.

## The rule this release corrects, before and after

Before the upgrade, on the modem this router actually runs:

```text
provision-plan → {"can_provision":false,"reason":"already_configured", …}  exit 4
connect        → no section owned by this package is bound to modem …      exit 4
```

That is the complaint that started the release: the page showed a modem, no
controls, and a paragraph explaining the refusal. After the upgrade, the same
modem and the same command:

```text
provision-plan → …,"can_control_bearer":true,"connection_section":"wwan",
                   "connection_owned":false                                 exit 4
```

The provisioning refusal is unchanged and still exit 4. Only the separate
bearer-control question is now answered, and answered by the same resolver the
action uses.

## Bearer control on a user-created interface

Driven through `/usr/libexec/apn-autoconfig-modem-control`, the same narrow
wrapper LuCI calls:

| Verb | Terminal state | Interface after |
|---|---|---|
| `disconnect` | success | down |
| `connect` | success | up |
| `reconnect` | success | up |

Afterwards the modem's own path was verified rather than assumed: `curl` bound
to the interface's effective layer-3 device returned HTTP 204.

**It is not adoption.** `uci show network.wwan` is byte-identical before and
after: same `apn`, `device`, `metric`, `proto`, and no ownership markers were
added. Both configuration-changing verbs still refuse the section:

```text
deprovision → no section owned by this package is bound to modem …   exit 4
provision   → cannot be provisioned: already_configured              exit 4
```

## A refusal that was correct, and worth recording

The very first `disconnect` was accepted and then ended `retryable`, with
`another APN or modem operation is already running (PID …); retry later`. The
service restart from the upgrade had started boot reconciliation, which held the
global APN lock. This is the serialized operation model doing its job across an
entry point that LuCI did not start, and it is the behaviour the release notes
describe rather than a defect. The retry on a free lock succeeded.

## Per-target last result, observed on an upgraded installation

Immediately after the upgrade the status reported **no** last result, rather
than the value the shared cache still held from 0.12.0. After the first
operation, `/etc/apn-autoconfig/targets/network_wwan/` contains `last-result`
and `last-result-code`, and the shared `cache/last-result` pair is gone — the
write path retires it once a per-target result exists. This is the upgrade
behaviour the fixtures assert, seen on real state.

## Browser gate

Performed against the installed package on the reference router, with the page
open. The following were verified directly:

- the four areas render as tabs with the status strip above them, and the strip
  is outside every panel;
- the production modem — bound to an interface the user created — offers
  **Connect**, **Reconnect**, **Disconnect** and the board's **Power-cycle
  modem**, and offers no provisioning or removal;
- a **Reconnect** started from the page was confirmed first with a dialog naming
  the interface (“This stops and restarts the interface wwan … No configuration
  is changed.”), reached `success` in the coordinator, and the card reported it;
- **Cancel** on a confirmation started nothing: no operation was recorded and
  the interface stayed up;
- manual APN entry is absent from the page body, opens as a dialog containing
  the fields, and cancels leaving nothing behind;
- every advanced disclosure is closed on load;
- help text is absent from the DOM until its control is activated, and returns
  to absent when closed;
- no full ICCID, IMSI, EID or modem identity appears anywhere before an explicit
  reveal, on any tab;
- the browser console is clean on a fresh load of the page. Errors seen earlier
  in the session came from the console buffer of an earlier navigation, not from
  this view; a clean tab loading only this page produced none.

Two things remain the maintainer's own judgement and are not claimed here: that
the page is comprehensible at a glance, and that help opens by tap on a real
touch device rather than only under a pointer.

## One change considered and rejected

The first browser pass flagged LuCI's **Save & Apply** footer as appearing while
the Modem tab was open, and a change was drafted to hide it outside Settings.
That was wrong and was reverted. The footer is LuCI's page-level footer, placed
outside the view's tabs by platform convention — the same convention every other
LuCI page with tabs follows, including the settings form's own General/Advanced
tabs. The page contains exactly one `.cbi-map`, it lives in the Settings area,
and the footer's Save and Reset act only on it. Hiding it would have broken a
convention users rely on and would have cost a retry loop reaching into LuCI's
own DOM, which is precisely the kind of thing that breaks on a LuCI update.

## Signed-feed smoke

Pending publication. It installs the released packages from the signed feed with
no `--allow-untrusted` and confirms the page works from the installed package.
