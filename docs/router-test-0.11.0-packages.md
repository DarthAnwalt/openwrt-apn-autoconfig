# 0.11.0 WH3000 package and interface validation

Date: 2026-08-15
Status: complete for everything that can be proven before publication. The
signed-feed install and the final removal/reinstall smoke remain, because they
require the release to be published first.

Supersedes the exploratory run in [`router-test-0.11.0.md`](router-test-0.11.0.md),
which validated the code from `/tmp` against installed 0.10.1 packages. This run
used the packages built by the official SDK.

## Live upgrade

GitHub Actions built all five packages with the OpenWrt 25.12.5 SDK. Their
checksums were verified on the router before installation, and a recovery
snapshot was stored on the persistent partition first.

`apk add` upgraded `apn-autoconfig`, `apn-autoconfig-modem`, the Huasifei
integration and `luci-app-apn-autoconfig` from 0.10.1 (LuCI 0.10.0) in one
transaction. Configuration survived: the pinned `reset_modem_id`, the enabled
`BTN_0`, the selected interface and the APN were unchanged, `wwan` stayed up,
both locks were clear and `apk audit` reported no modified file.

One upgrade behaviour worth recording: `connect_wait_seconds` is new in this
release's shipped config, and apk correctly kept the existing conffile and wrote
`.apk-new`, so the option is **absent** on an upgraded install. The runtime
default applies, so nothing breaks, but new options do not reach existing
installations. Anything that must take effect on upgrade cannot be introduced
as a config default alone.

## Read-only refusal on the production modem

Against the live modem, `provision-plan` returned `already_configured`, and
`uci show network` was byte-identical before and after with zero uncommitted
changes. The installed package exposes `provision`, `deprovision`, `connect`,
`disconnect`, `reconnect`, `provision-plan`, `forget-target` and `apply-manual`.

## Interface, in a real browser

The page was opened in a browser for the first time in this release, and it
immediately found a defect the fixtures could not.

The modem setup card printed the raw JSON answer as an error message —
including the unmasked modem identity, on a page that masks that identity in
the row directly above. `provision-plan` prints a complete answer and carries
the refusal class in its exit status, which is correct for a command; the
view's generic helper treated any non-zero exit as a failure and used the
output as the message. Whether the body parses now decides. The error branch no
longer echoes command output at all.

After the fix the card shows the plain-language explanation, with no raw output
and no unmasked identifier. Both were re-checked in the browser against the
rebuilt package.

The card was also driven as a user: **Remove setup** opened a confirmation that
named the exact interface and stated that interfaces the user created are never
touched, and confirming it ran the operation through rpcd, the narrow wrapper
and the coordinator.

Two `uci/get` "Access denied" errors appear in the browser console on every
page load of this router, including pages this project does not provide. They
were traced rather than assumed:

- every UCI config on the router, including all of this project's, is readable
  by the logged-in session, so no ACL grant is missing;
- the router logs no denial, and every `ubus` call after load returns 200;
- reproducing `uci.get` with the null session returns exactly the observed
  `-32002 Access denied`;
- the only LuCI resources that declare UCI calls are `luci-base`'s `uci.js`
  and the wireless view.

So it is a `luci-base` bootstrap call issued before the session is applied. It
is harmless — the page works and the session is valid afterwards — and it is
neither caused by nor fixable from this project without patching LuCI base.

## Provisioning with the installed package

With `wwan` parked, `provision-plan` reported the modem as provisionable, and
provisioning was started through `/usr/libexec/apn-autoconfig-modem-control` —
the same narrow path LuCI uses. It was accepted, reached `success`, produced
`apnmodem1` with all three ownership markers and the APN written by the engine,
and a real HTTPS request over the new interface succeeded. Both locks were
clear afterwards.

Background `deprovision` through the same wrapper then removed the section, its
provisioning baseline and the engine's per-target state, leaving only
`network_wwan`. `wwan` was restored to its captured values with verified
connectivity, `BTN_0` re-enabled, no uncommitted changes and no test artefact.

## A misleading result, and why

The first attempt at the removal test appeared to show the background path
failing to clean up. It was the test harness, not the product: the safety
watchdog fired on its deadline and restored `wwan` by deleting the
project-owned section directly, so the deprovision that followed found nothing
to remove and its cleanup never ran. The state left behind was the watchdog's.

Two lessons for the next hardware session. Re-arm or disarm the watchdog
deliberately around each measurement, because its restore path deletes
project-owned sections without going through `deprovision`. And synchronise on
a **new** operation id rather than on any terminal state: polling for
`success` after starting an operation can return the previous operation's
result before the new worker has written anything.

## Remaining

The signed-feed install without a trust bypass, and the final removal and
reinstall smoke, both of which need the release published. No physical `BTN_0`
press was performed in this run; that path is unchanged since its 0.10.1
validation.
