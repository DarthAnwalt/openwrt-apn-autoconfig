# 0.12.0 native MBIM test and release plan

Status: the runtime work is implemented and the fixture gate passes. The SDK,
package-lifecycle and hardware gates are open, and nothing here has been
attempted on hardware. The contract tests below are written as requirements;
each one that now exists is an executable assertion in `tests/run-tests.sh`,
`tests/run-tests-modem.sh` or `tests/test-luci-roaming-policy.js`.

0.12.0 completes the native MBIM vertical slice defined in
[`roadmap.md`](roadmap.md), against the accepted
[`mbim-contract-v1.md`](mbim-contract-v1.md). The release is finished when a
CDC-MBIM modem can be discovered, provisioned, given a profile, verified against
the real Internet, controlled and rolled back — on hardware. An MBIM parser that
passes fixtures is a step, not the release.

Two maintainer decisions frame the plan. The reference RM520N-GL is switched
into MBIM composition for the hardware gate and restored afterwards, so MBIM can
ship with a hardware claim rather than as a synthetic one. And MBIM roaming
policy is implemented for both reading and writing, using the `allow_roaming` +
`allow_partner` pair.

Three facts from the contract cause most of the tests below, and each one is
easy to get wrong in a way fixtures would not catch by accident:

- `umbim`'s exit status is state, not failure. A modem registered in roaming
  exits non-zero from `registration`, and treating that as an error would make a
  perfectly healthy roaming modem look broken.
- `-t` suppresses the MBIM OPEN and `-n` suppresses the CLOSE. Getting the
  combination wrong either talks into a closed device or closes the session
  netifd is holding for a live bearer, dropping the connection this project
  exists to keep.
- `umbim connect` silently discards the username and password when the auth
  value is not exactly `pap`, `chap` or `mschapv2`. A normalized `pap-or-chap`
  written verbatim would produce an unauthenticated dial with no error anywhere.

## In scope

- an MBIM identity adapter with SIM and registration identity;
- backend-owned profile capture, write, restore and exact rollback;
- auth and IP-family attempt planning;
- readiness on the dynamic `${interface}_4` / `${interface}_6` interfaces;
- MBIM inventory classification, ownership and provisioning of a staging
  section;
- connection control on a project-owned MBIM section;
- roaming policy read and write with the two-option pair; and
- the complete LuCI workflow for an MBIM modem.

## Explicitly out of scope

- `mbimcli` or any new package dependency;
- PIN unlock and SIM-lock handling;
- MBIM firmware profile mutation, or any bearer lifecycle outside netifd;
- generic writable AT control (0.13.0), Fibocom (0.14.0), eSIM (0.15.0); and
- adoption of user-created sections, which stays refused per
  [`provisioning-contract-v1.md`](provisioning-contract-v1.md).

## Contract tests before implementation

Define fixtures and assertions before the corresponding runtime code exists.
Prefer executable fixture assertions over grepping for implementation text. The
`umbim` mock records every invocation's full argv so the read-only and session
rules are asserted from behavior rather than by reading the adapter.

### Read-only and session discipline

1. across every identity path, the recorded argv contains only `subscriber`,
   `home` and `registration` — never `connect`, `disconnect`, `attach`,
   `detach`, `unlock`, `config` or `radio`;
2. with no netifd session open, the adapter opens its own: no `-t` and no `-n`,
   so `umbim` closes the device again;
3. with a netifd session open, every call carries both `-n` and a `-t` id from
   the private high range, so netifd's live session is neither closed nor
   collided with;
4. a section in transition — `tid` state present while the interface is not up,
   or a pending interface — is exit 3 retryable and issues no `umbim` call at
   all;
5. the identity lock is the same per-device namespace `apn-autoconfig-qmi` uses,
   so an MBIM read and a QMI identity transaction on one device cannot overlap;
6. a hanging `umbim` is terminated by the outer bound and reported as exit 3,
   including on an image with no `timeout` executable.

### Response parsing

7. `registration` exiting `4` (roaming) or `5` (partner) is a valid answer that
   produces valid identity, not a failure;
8. `subscriber` exiting with `sim-not-inserted`, `bad-sim`, `not-activated`,
   `device-locked`, `failure` or `not-initialized` each exit 3 with its own log
   line and no identity output;
9. a truncated message, a `255` exit and unparseable output are exit 1;
10. a missing or non-numeric `simiccid` fails closed;
11. `dont display subscriberID: 1` yields valid identity with an empty IMSI
    rather than a refusal or a guessed value;
12. `partner` registration reports `roaming` true, and `home` reports it false;
13. `operator_id` comes from the home provider and is never filled from the
    serving provider while roaming;
14. `access_technologies` is empty even when `availabledataclasses` and
    `currentcellularclass` are populated;
15. `rssi` of `0` and `99` leave `signal_quality` empty; a value in `1`–`31`
    maps through the documented dBm conversion; empty signal never makes valid
    identity unavailable.

### Device resolution

16. zero and multiple MBIM control-device matches below a `devpath` both fail
    closed instead of selecting by enumeration order;
17. a device name outside `/dev/cdc-wdm<N>` and `/dev/wwan<N>mbim<M>`, a
    non-numeric suffix, a path separator and a symlink escaping the sysfs root
    are all refused before any command runs.

### Profile write and rollback

18. exactly `apn`, `username`, `password`, `auth` and `pdptype` are captured,
    written and restored; no other option in the section is touched;
19. `pdptype` is written as `ipv4`, never QMI's `ip`;
20. a normalized `pap-or-chap` candidate is never written verbatim; it expands
    to `chap` then `pap`, and the effective value is what the cache and the
    reconciled state record;
21. a provider-label refresh still matches a database `pap-or-chap` row when the
    effective stored auth is `chap` or `pap`;
22. an `ipv4v6` bearer that does not become ready retries exactly once with
    `ipv4` and records IPv4 as effective; no other family is silently changed;
23. a pre-existing `ipv6=0` makes an IPv6-only candidate incompatible and
    reduces a dual-stack candidate to IPv4, and is never rewritten;
24. failure at each step restores the exact prior profile, and a real `TERM`
    during the destructive window restores it and releases the locks in reverse
    order.

### Readiness and verification

25. connectivity verification waits for an addressed `${interface}_4` or
    `${interface}_6` matching the effective family, not merely for the parent
    section to report up;
26. a bearer that never addresses either dynamic interface is retryable rather
    than a silent success;
27. the generalized readiness helper keeps the QMI behavior it replaces
    unchanged.

### Roaming policy

28. `allow`, `block` and `default` each produce the exact option pair, including
    deleting both for `default`;
29. a mixed or non-boolean pair reads back as `invalid` and is never normalized
    or guessed;
30. both options absent reads back as `default-block` for MBIM, while
    ModemManager keeps `default-allow`;
31. applying `block` while registered in roaming brings the interface down;
32. `roaming_policy_read` and `roaming_policy_write` are reported as separate
    booleans and no consumer infers policy support from a backend name.

### Provisioning, inventory and lifecycle

33. an MBIM modem is provisioned as `proto=mbim` with the control device, the
    three ownership markers, `disabled=1`, `auto=0` and no `apn` option;
34. every refusal reason from the provisioning contract behaves identically for
    MBIM as for QMI, and rollback removes exactly the created section;
35. inventory classifies an MBIM modem without opening a control channel: the
    `umbim` mock records no invocation during a scan;
36. `connect`, `disconnect` and `reconnect` drive an MBIM project-owned section
    and refuse a user-created one;
37. the new adapter is installed by the package, removed on removal, and an
    offline image-root install performs no live action;
38. upgrade from 0.11.0 with a modem already present preserves configuration and
    both locks.

### LuCI

39. an MBIM modem offers the same capability-driven controls as a QMI one, and
    anything refused is explained rather than rendered as a dead control;
40. the roaming control's labels are backend-specific, because "default" means
    allowed on ModemManager and blocked on MBIM;
41. a custom option pair is displayed as custom and cannot be silently
    normalized by opening the page;
42. identifiers stay masked, controls stay disabled while an operation runs, and
    every state-changing verb is confirmed first.

## Hardware gate

Nothing below has been attempted. The reference modem is currently in QMI
composition, owned by ModemManager, and serves as the backup WAN behind the WiFi
uplink. The run therefore changes the modem's USB composition and must restore
it.

1. Snapshot the router configuration, the modem state and the installed package
   set; generate the restore script from live values and rehearse it before the
   first change.
2. Park the production `wwan` target as recorded in
   [`router-test-0.11.0.md`](router-test-0.11.0.md).
3. Stop ModemManager for the duration of the run and confirm inventory reports
   the modem's control owner as `none` rather than `conflicting`.
4. Switch the modem to MBIM composition and confirm `cdc_mbim` binds and a
   control device appears; capture the real `umbim subscriber`, `home` and
   `registration` output and compare it against the fixtures, since the fixtures
   were written from source rather than from hardware.
5. Discovery: the modem appears with `protocol=mbim`, stable identity and
   `owner_state=netifd-direct` or `none`, and `provision-plan` answers without
   opening a control channel.
6. Provision, reconcile through the APN engine, verify real Internet access on
   the MBIM bearer through its effective route, and promote autoconnect.
7. Prove the dynamic-interface readiness rule on real hardware, including the
   `ipv4v6` case and, if the SIM allows it, the IPv4 downgrade.
8. Roaming policy: `allow`, `block` and `default`, with the observed option pair
   and the resulting interface state recorded each time.
9. `disconnect` / `reconnect`, then a forced failure with a wrong APN and a real
   `TERM` during the destructive window, each proving the exact restore.
10. `deprovision`, `forget-target`, and a byte-identical `uci export network`
    against the snapshot.
11. Restore the QMI composition, restart ModemManager, restore `wwan`, and
    confirm production connectivity and the 0.10.1 reset/`BTN_0` matrix still
    behave as validated.

Record everything in `docs/router-test-0.12.0.md`. Host addresses, keys and
topology stay out of the published record, as in every earlier one.

## Release gate

`sh scripts/verify.sh`; the official OpenWrt 25.12 SDK build with APK inspection
of the produced package rather than inference from the source tree; the package
lifecycle matrix (clean install, offline image-root install, 0.11.0 upgrade,
removal, reinstall) with hardware already present; the hardware gate above; then
tag, publish and the signed-feed install/removal/reinstall smoke with no
`--allow-untrusted`.

MBIM stays `implementation_state: alpha`, `validation_state: synthetic` and
`hardware_validated: false` until step 11 of the hardware gate is recorded.
Every defect found at any gate gets a fixture regression before the fix is
considered complete.
