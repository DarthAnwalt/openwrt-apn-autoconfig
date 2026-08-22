# 0.15.2 corrective test and release plan

Status: **complete; v0.15.2 is published and every release gate passed.** The
post-publication signed-feed smoke included a fresh installation of all six
packages on the reference router. Detailed router evidence is in
[`router-test-0.15.2.md`](router-test-0.15.2.md). 0.15.2 is a defect release
against the published 0.15.1 packages. Every defect below was found on the
reference hardware after an ordinary reboot, not by review.

The release is finished when a router with two modems behaves like a router with
one — automatically, without being asked to choose — and when a modem this
package set up itself is still recognised as its own after a reboot.

## What went wrong on 0.15.1

Three defects, two of them sharing a root cause.

**1. A reboot made the package forget its own modem.** The FM350-GL exposes no
USB serial, so its strong identity is the IMEI an explicit AT read learned, and
discovery is forbidden to probe for one. That IMEI lived in
`/var/run/apn-autoconfig-modem`, which is tmpfs. After the reboot the modem was
`weak-vidpid:2-1.3:0e8d:7127` again while `network.apnmodem1` still recorded
`apn_autoconfig_modem_id='imei:016177002734885'`. The identity lookup missed,
the section stopped being recognised as project-owned, and the page reported
`Unidentified (0e8d:7127)` belonging to "a network interface you created, so its
configuration is left alone" — about an interface the package had created
itself. Nothing looked broken; it looked deliberate.

**2. Two modems stopped the suite instead of doubling its work.** `interface=auto`
resolved a target only when exactly one writable target existed, and otherwise
exited 4 with `multiple writable cellular targets found; select one explicitly`.
Every command inherited that, including `status`, so the LuCI page showed
"Target unavailable" and offered a choice the user had to make before anything
would work again. A program whose purpose is to configure modems automatically
stopped doing so at the moment there was a second modem to configure. The
hardware button, which starts `action-start modem-reset`, failed the same way.

**3. The roaming policy could not be set on an AT-dialed target.** The engine
gated `roaming-policy-set` on the `profile_write` capability. `atdial` owns no
profile fields of its own — that is permanent, not unimplemented — so it reports
`profile_write:false` and `roaming_policy_write:true`, and every roaming command
against it failed on the wrong capability. Both LuCI's roaming controls and the
CLI were affected. This is also what blocks the roaming evidence 0.15.0 owed.

## In scope

- persistent identity evidence, and the volatile/persistent split;
- synchronous migration of the 0.15.1 volatile identity cache during upgrade;
- recovery of a project-owned section whose recorded identity went stale;
- automatic mode as "every managed target", including exit-class aggregation;
- the target selector in LuCI, and per-modem scoping of the controls that
  belong to one modem;
- the roaming-policy capability gate;
- the roaming hardware evidence 0.15.0 deferred, on a roaming SIM.

## Explicitly out of scope

- `modem-reset` fan-out. The power-cycle is one physical operation on one board
  modem; it acts on the target it is given, or on the first managed one.
- unrelated changes to the AT-dial handler's dial sequence; resolving the
  deliberate post-reboot identity demotion before port lookup is part of the
  reboot fix;
- the Intel XMM path, which stays `alpha`/`synthetic`.

## Fixture assertions

In `tests/run-tests-modem.sh`:

- an identity read writes the IMEI and the model strings to the persistent
  directory and **not** to the volatile one;
- wiping the volatile state directory — a reboot — keeps the modem model but
  returns it to `weak-vidpid` until a fresh AT identity read corroborates the
  persistent IMEI for that USB enumeration; discovery probes nothing;
- a different modem of the same VID:PID in the same socket cannot inherit the
  previous modem's strong IMEI identity;
- a simulated 0.15.1 volatile cache is migrated before tmpfs is wiped and its
  model evidence remains available after the simulated reboot;
- a project-owned section whose recorded `apn_autoconfig_modem_id` no longer
  resolves is still recognised through its physical path, reports
  `already_provisioned`, is owned for bearer control, and nothing is written to
  the configuration to establish it;
- the high-frequency `inventory-json` path does not repeat a recovery notice on
  every poll;
- the claim is refused when the id the section records still names a modem that
  is present, so one modem can never take another's section.

In `tests/run-tests.sh`:

- two writable targets no longer make any command fail; `status-json` reports
  the first managed target;
- the order is the route metric, not the section name;
- `targets-json` reports `managed` for each target, and a staged project-owned
  section or administratively disabled user section is not managed;
- `apply` in automatic mode configures **every** managed target;
- a target blocked by roaming policy does not stop the others, and the aggregate
  result remains blocked rather than hiding it behind another target's success;
- a roaming-policy change with several managed targets requires an explicit
  target and writes nothing before refusing;
- `apply-manual` and `reset` refuse with exit 4 when several targets are managed
  and none was named;
- the action worker forwards `TERM` to the engine for a target of `auto` as well
  as for a named one.

## Hardware gate

On the WH3000 with both modems attached — the RM520N-GL under ModemManager and
the FM350-GL on `apn_atdial` — against installed packages:

1. **The reboot case, reproduced and then fixed.** Before the upgrade, capture
   the defect as observed. After it, reboot and confirm the FM350 comes back
   with its Fibocom/FM350 model and project-owned section rather than as
   unidentified/user-created. Confirm discovery initially stays read-only and
   weak, then an explicit identity/status read corroborates `imei:…` for the
   current enumeration.
2. **Both modems are managed.** `apn-autoconfig targets-json` reports both as
   managed; `status` names one and lists both; a reconcile started with no
   target reaches both, and the per-target results appear in the log.
3. **One target does not hide the other.** With the roaming SIM in the FM350 and
   roaming blocked, a reconcile of both must leave the RM520N working and report
   the FM350 as blocked by policy rather than as a failure.
4. **Roaming, the full cycle.** Select the AT-dial target explicitly and set
   its policy to allow; confirm automatic multi-target view cannot grant that
   permission. Then let the engine choose and verify an APN over the roaming
   network, then set it
   back to block and confirm the handler refuses the dial again.
   The SIM has a 100 MB allowance: the connectivity check is a single
   `generate_204` request per candidate, so the whole gate is expected to cost
   well under 5 MB. Record the data actually used.
5. **The browser pass**, which 0.15.0 also owed, now including the target
   selector: switching targets scopes the panels and the buttons, and no page
   state shows "Target unavailable" with two modems attached.

## Release gate

`sh scripts/verify.sh`, the official SDK build and APK inspection, the package
lifecycle suite, the hardware gate above, and the signed-feed smoke after
publication. Nothing here promotes an implementation state: no backend's
maturity changes in 0.15.2.

All gates passed. Tag `v0.15.2` resolves to main commit `5b4fc5b`; GitHub Actions
run [32552652875](https://github.com/DarthAnwalt/openwrt-apn-autoconfig/actions/runs/32552652875)
successfully rebuilt the packages, published the Release and deployed the
signed repository. The router then accepted the public index without
`--allow-untrusted`, fetched all six published APKs with matching release
checksums, and installed them from the feed. The final router state preserved
both managed targets, the persistent FM350 identity, explicit roaming block and
the exact pre-smoke UCI configuration.
