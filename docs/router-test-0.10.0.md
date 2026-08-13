# 0.10.0 WH3000 hardware validation record

Date: 2026-08-13  
Status: partial hardware gate passed; next session prepared, release gate open

## Test system

- Huasifei WH3000 Pro running OpenWrt 25.12.5;
- internal Quectel RM520N connected through ModemManager and netifd target
  `wwan`;
- draft PR 27, official SDK artifact for commit `ae08a92` from GitHub Actions
  run `31716017201`;
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

## Required next hardware session

1. Install the next official SDK artifact containing the bounded core `mmcli`
   calls; verify checksums and preserved configuration.
2. Repeat one public compatibility reset while recording router-clock stage
   timings and confirm the same modem, owner, SIM, target and connectivity.
3. Exercise the actual physical `BTN_0`: press must be inert; one enabled
   release must queue exactly one composite operation; repeated releases must
   not overlap.
4. Confirm LuCI observes an externally started operation through its real busy
   and terminal states without exposing private modem/SIM identifiers.
5. Complete signed-feed install and removal/reinstall lifecycle tests before a
   release candidate is called ready.

No further GPIO or modem mutations should be run merely to reproduce desktop
timing. The next session starts from the bounded build and the steps above.
