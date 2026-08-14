# 0.10.0 WH3000 hardware validation record

Date: 2026-08-14
Status: modem and button hardware paths passed; live signed-feed smoke pending

## Test system

- Huasifei WH3000 Pro running OpenWrt 25.12.5;
- internal Quectel RM520N connected through ModemManager and netifd target
  `wwan`;
- draft PR 27, official SDK artifacts through commit `2cd8708` from GitHub
  Actions run `31798760086`;
- recovery snapshot stored on the router before installation;
- modem and SIM identifiers intentionally omitted from this record.

## Completed evidence

- Live upgrade from the released 0.9.2 packages to 0.10.0 completed with the
  existing APN state and configuration preserved.
- Inventory converged to one unambiguous QMI modem owned by ModemManager and
  bound to `wwan`. Board reset capability remained disabled until the exact
  strong modem identity was explicitly pinned.
- The first compatibility reset exposed a real readiness race: raw USB
  re-enumeration completed before ModemManager had recreated its primary-SIM
  state. Failure cleanup restored power, the interface and both locks. Commit
  `ae08a92` adds the resulting owner and SIM readiness barriers.
- After installing the `ae08a92` SDK artifacts, the public
  `apn-autoconfig modem-reset` path exited successfully. GPIO returned to the
  powered-on value, both operation locks were clear, `wwan` was up and the
  reconciled APN passed the configured connectivity check.
- A direct coordinator reset was interrupted after the selected QMI control
  device disappeared from sysfs. It exited 143 and restored the powered-on GPIO
  value, the netifd interface and both locks. The temporary 30-second power-off
  test setting was restored to the configured five seconds.
- With commit `3223d75` installed, one physical `BTN_0` release started the
  background `modem-reset`; a second release 28 seconds later arrived while the
  first operation was still running. Router evidence showed two release events,
  one GPIO power-cycle, one successful terminal result, clear locks and `wwan`
  restored after 60 seconds. The inherited handler's pre-launch log described
  both releases as starts even though the second was safely rejected as busy;
  the follow-up handler fix parses `accepted`/`busy` and reports that duplicate
  truthfully without changing the verified hardware event contract.
- During that physical operation the core action API reported
  `running`, `busy=true`, `action=modem-reset`. After completion, the deployed
  rpcd `file.exec` call used by LuCI returned code 0 with `state=success`,
  `busy=false`, exit code 0 and the expected terminal message. No modem or SIM
  identifier was needed in either status path.
- The official `2cd8708` WH3000 integration APK passed its published checksum
  and was reinstalled without invoking a reset. The enabled `BTN_0`
  configuration was preserved, both operation locks remained clear, `wwan`
  stayed up on `wwan0`, and the installed handler hash matched the reviewed
  source (`8903bf03fd48c995ce9c60d3531f8daf53c1972b1e932689c51d04aba0ae9d41`).

## Router-clock timing of the successful reset

The measurements below come from router log and kernel monotonic timestamps,
not from desktop SSH/tool duration:

| Stage | Observed duration |
|---|---:|
| Configured power-off interval | 5 s |
| USB disconnect to new SuperSpeed enumeration | about 12.05 s |
| Power restored to original ModemManager owner returned | 39 s |
| Owner returned to readable primary SIM | 5 s |
| SIM ready to reconciled connectivity verified | 3 s |
| Power-off start to verified connectivity | 52 s |
| Power restored to verified connectivity | 47 s |

Read-only measurements on the router took less than one second for `mmcli -L`
and inventory, and about one second each for resolve, modem status and core
status. An earlier statement that preliminary inventory exceeded two minutes
was invalid: it was inferred from desktop tool-call wall time and is not router
runtime evidence.

The sysfs GPIO value readback stayed at its powered-on value while USB
disconnect proved that the board integration had removed modem power. Hardware
interruption tests on this board must therefore synchronize on disappearance
of the selected control device (or an equivalent kernel event), then verify the
post-condition GPIO value; polling the value file for the transient off state
is not a valid oracle.

## Post-publication live repository smoke

1. Publish the verified commit as `v0.10.0`, allowing the release workflow to
   update the signed project feed.
2. Install from that live feed without `--allow-untrusted`, remove the LuCI,
   board integration, modem-control and core packages, then reinstall all five
   first-party packages while verifying restored configuration and connectivity.

No further GPIO or modem mutations should be run merely to reproduce desktop
timing. The next session starts from the published `v0.10.0` feed and the
package-lifecycle smoke test above.
