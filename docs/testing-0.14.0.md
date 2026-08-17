# 0.14.0 AT test and release plan

Status: complete. Evidence is recorded in
[`router-test-0.14.0.md`](router-test-0.14.0.md).

Original status: planned. No implementation had started. The hardware first-contact
census was performed on 2026-08-16 before implementation and is recorded below;
three of its findings changed the contracts, which is why it was done first.

0.14.0 adds the third and last identity backend, the bounded AT transport it
needs, and the reset-method contract, against
[`modem-contract-v1.md`](modem-contract-v1.md) and
[`backend-contract-v1.md`](backend-contract-v1.md). The release is finished when
a modem that speaks only 3GPP AT is identified, matched against the provider
database and displayed honestly, when two modems present at once never borrow
each other's ports or identities, and when `modem-reset` works on a modem the
board GPIO cannot reach.

This release has the mirror of 0.13.0's problem. There the fixtures could not
judge legibility; here they cannot judge the transport. **Every genuinely
dangerous behaviour in this release exists only on real hardware**: a port that
accepts a write and then never answers, a port that answers `OK` while being a
GNSS or debug channel, a reset that removes the port in the middle of its own
command, and a re-enumeration that renumbers a *neighbouring* modem's tty nodes.
A fixture AT port answers instantly and correctly by construction, which is
precisely the case that never breaks. The hardware gate is therefore where this
release is actually decided.

## In scope

- same-device AT port resolution by observed role, and its cache/revalidation;
- the bounded executor, including the watchdog path for images with no external
  `timeout`;
- the mandatory AT port lock as the innermost level of the existing order,
  including making the QMI adapter's existing AT fallback take it;
- AT identity in `apn-autoconfig-modem`, emitting the v1 identity TSV;
- the quirk table mechanism, keyed by manufacturer/model, with an empty default;
- `reset_method` selection by control owner, and `AT+CFUN=1,1` as the third
  implementation;
- the additive v1 schema fields and the LuCI rows that display them;
- two simultaneously present modems, moving from fixture coverage to hardware
  coverage.

## Explicitly out of scope

- any AT profile write; profile fields remain UCI options applied by netifd;
- free-form AT from any public control, UCI, the environment or the GUI;
- band selection, SIM slot switching, SMS, USSD, firmware or radio-mode control;
- the Fibocom netifd protocol, which is 0.15.0;
- an APN-engine-facing AT adapter. The engine only speaks about netifd targets
  and an AT-managed modem has none until 0.15.0, so the adapter would be a
  connector to a socket that does not exist. Which component answers the engine
  is decided there, against a real caller; both candidates are recorded in
  [`backend-contract-v1.md`](backend-contract-v1.md);
- ModemManager inhibition, which is an eSIM-transport problem for 0.16.0;
- per-target lock granularity and automatic reset escalation, both deferred to
  0.17.0 and recorded in [`architecture.md`](architecture.md);
- QMI-native reset (`--set-device-operating-mode reset`), which the reset-method
  table can accept later as a fourth row when hardware needs it.

## Fixture assertions before implementation

In `tests/run-tests-modem.sh` and `tests/run-tests.sh`, executable rather than
grepped.

### Port resolution

1. a modem with one responding port and three silent ones resolves that port;
2. a port that answers phase 1 but returns no model string in phase 2 is
   rejected, and a modem whose only responder is such a port reports
   `at_identity: false`;
3. several fully responding ports on one proven USB device resolve
   deterministically to the lowest index and leave `ambiguous: false`, which is
   the rule this release reverses;
4. ports belonging to a *different* USB device are never probed, asserted by
   recording every probe target and comparing it against the correlated set;
5. a cached port that has vanished, moved to another USB device, or stopped
   answering is discarded and resolution runs again;
6. resolution does not run at all while `owner_state` is `modemmanager` or
   `conflicting`, asserted by an empty probe record rather than by a return
   value;
7. a symlink escaping the configured sysfs root fails closed.

### Bounded execution

8. a port that accepts a write and never answers is abandoned within the bound,
   and the command returns the retryable class;
9. the same holds with no external `timeout` on `PATH`. This is **not** the
   exotic case it looks like: the reference router has no `timeout` executable,
   so the watchdog is the only path that has ever run there, including for the
   already hardware-validated QMI AT fallback. It is tested as the primary
   implementation and the external-`timeout` path as the variant, not the other
   way round;
10. the watchdog terminates and reaps its child, leaving no process behind,
    asserted against the process table rather than inferred;
11. a timed-out port is not retried with an alternate ICCID spelling, while a
    port returning an immediate command error is;
12. a `TERM` during a probe releases the port lock and leaves no scratch file;
13. the first exchange on a port whose echo is still on parses correctly, and a
    modem presenting one echoing and one silent port yields identical identity
    from both.

### Cache and laziness

14. an inventory scan performs **no** probe at all, asserted from an empty probe
    record, and reports `at_identity: false` until a resolution has run;
15. a request that needs AT identity triggers resolution, and a second request
    reuses the cache without probing;
16. a port recorded as failed is skipped on the next sweep;
17. the cache is keyed by stable USB interface path: after a re-enumeration that
    renumbers tty nodes, no verdict is applied to a port it was not recorded
    for, and entries whose interface path is gone are discarded;
18. a selection cached while a modem was unowned grants nothing once
    ModemManager claims it: `at_identity` drops to false and access is refused.
    This is not hypothetical — on the reference router ModemManager publishes a
    freshly attached modem only after a delay, so the unowned-then-owned
    sequence is the normal one rather than a race.

### Lock

19. two concurrent identity requests for one port serialize, and neither
    proceeds without the lock;
20. two concurrent requests for *different* ports do not serialize against each
    other at this level;
21. a lock whose owner is dead is reclaimed only under the `.reclaim` guard,
    reusing the existing shared assertions;
22. the AT adapter and the QMI adapter's AT fallback contend on one device and
    exactly one proceeds at a time.

### Identity

23. the v1 identity TSV is complete and well-formed from a fixture modem;
24. `operator_id` is empty and the matcher still selects the right provider from
    the IMSI prefix, for both a five-digit and a six-digit database row;
25. `<stat>` 3 maps to denied and is reported as permanent, not retryable;
26. `<stat>` 6 and 7 map to home and roaming rather than to unregistered, from
    `AT+CREG?` specifically, since that is the source that produces them;
27. `AT+CSQ` 99 and `AT+CESQ` 255 leave `signal_quality` empty rather than
    reporting zero signal;
28. a `CESQ` reply carrying more than six fields is parsed rather than
    discarded, with the NR fields unknown and the LTE fields usable;
29. malformed, truncated and echo-polluted replies fail closed rather than
    yielding a partial identity;
30. an ICCID of implausible length is rejected, reusing the existing digit
    validation;
31. the ICCID ladder stops at the first spelling that answers, and a modem that
    rejects the vendor spelling with an immediate error still yields an ICCID
    from the standard one.

### Reset methods

32. each of `gpio`, `modemmanager` and `at` is selected exactly when its
    preconditions hold, and `reset_method` reports it;
33. `gpio` wins where its preconditions hold, preserving released behaviour;
34. a second modem on the same board does not inherit the pinned modem's GPIO
    reset;
35. a soft reset whose port disappears without a final `OK` is treated as
    success pending re-enumeration, not as a transport failure;
36. a soft reset whose modem never returns is a terminal failure with the
    correct class, distinguishable from 35;
37. a real `TERM` during the destructive window restores the interface and
    releases both locks in reverse order;
38. `capabilities.reset` true never implies any method has been observed to
    work.

### Compatibility

39. `apn-autoconfig modem-reset` and `action-start modem-reset` keep their
    released behaviour and exit codes on the pinned GPIO modem;
40. a v1 consumer that ignores the new schema fields behaves exactly as before;
41. no command leaves a scratch file in `/tmp`, extending the 0.13.2 regression
    to the new commands.

## Hardware gate

The reference router carries the internal RM520N-GL in its M.2 slot, owned by
ModemManager and resettable through the Huasifei GPIO. For this gate an FM350-GL
in a USB carrier is attached alongside it, giving both control-owner classes and
both reset methods on one board at the same time.

### First contact — done 2026-08-16, before implementation

Completed on the reference router with both modems attached. Identifiers and
host topology stay in the maintainer's local notes; the conclusions that shape
the release are these, and three of them changed the contract:

1. the FM350 exposes **seven tty nodes and no network device at all.** Its
   RNDIS interface pair has no driver bound and `rndis_host` is not loaded, so
   0.15.0's protocol handler must bind the driver itself before a netdev exists;
2. **five of the seven ports accept a write and never answer.** Two answer, both
   return the same model string and the same values for every later read, which
   is the live case for "redundancy, not ambiguity";
3. the two responders differ in **echo state at the same moment**, so echo is a
   per-port property and the first exchange must tolerate its own echo;
4. the modem exposes **no USB serial**, so its strong identity depends on
   AT-supplied IMEI — the `imei` tier finally has a device that needs it;
5. ModemManager claims **both** modems — but it publishes the second one only
   after a delay, so a scan run at attach time sees it unowned and a later scan
   sees it owned. It is slow for the same reason our own sweep is: most of the
   ports never answer, so every probe has to reach its timeout. It also holds
   the second modem as "model unknown", having claimed a device it cannot drive.
   Two consequences: exercising the AT path on that modem needs a window in
   which ModemManager does not own it, and **ownership can change after
   attachment**, so a port selection cached during an unowned window must never
   become a licence once ownership arrives;
6. a live SIM is registered on 5G NSA and its network has 23 rows in the shipped
   provider database, so identity through matching can be exercised end to end;
7. **the router has no `timeout` executable.** See the gate note below.
8. `AT+CREG?` reports `<stat> 6`, and `AT+CESQ` returns more than six fields.
   Both were absent from the planned mapping and are now in the backend
   contract.

The remaining hardware steps below have not been performed.

### Two modems at once

9. both modems appear in inventory with distinct `modem_id`s and
   `ambiguous: false`;
10. neither record borrows the other's `at_device`, `control_device` or
    `data_device`, checked against the census above rather than assumed;
11. the RM520N reports `owner_state: modemmanager` and receives no AT probe at
    all, verified from the router's own process/serial activity, not only from
    our logs;
12. the FM350 resolves exactly one AT port by role and yields a complete
    identity;
13. its identity matches the correct provider from the database with
    `operator_id` empty;
14. an APN operation on one modem reports the other as busy — the deferred
    global-lock behaviour, recorded here as expected so it is not filed as a
    defect.

### Reset

15. `modem-reset` on the RM520N selects `gpio`, behaves exactly as released, and
    the FM350 is unaffected throughout;
16. `modem-reset` on the FM350 selects `at`, and the vanished port during
    `AT+CFUN=1,1` is reported as success pending re-enumeration;
17. after that reset the FM350 returns with the same `modem_id`, even if its tty
    indices changed. Note that its `modem_id` depends on AT-supplied IMEI, so
    this also exercises re-resolution after the cache was invalidated;
18. **the neighbouring modem survives the renumbering**: if the kernel reassigns
    tty indices across the re-enumeration, the RM520N's record still resolves to
    its own ports and its own identity. This is the headline test of the
    "names are attributes, not identity" invariant, and the census showed the
    two modems' tty ranges are adjacent, so renumbering is plausible rather than
    theoretical;
19. `modem-reset` on the RM520N with ModemManager stopped, or a deliberate
    `mmcli --reset` run, covers the `modemmanager` method;
20. an interruption during the FM350 reset leaves the interface and both locks
    restored.

### Optional window: netifd-direct QMI

21. with ModemManager stopped and the RM520N raised as a native QMI target, the
    record reports `owner_state: netifd-direct`, AT resolution is now permitted
    on it, and `reset_method` becomes `at`.

This step needs a deliberate configuration change on a live router and must be
scheduled and reverted explicitly, as the MBIM composition switch was in 0.12.0.
Without it, `netifd-direct` AT ownership ships with fixture evidence only and
must be recorded as such.

### Browser pass

22. both modems appear, each with its identity, protocol, owner and
    `reset_method`;
23. the AT-only modem explains that no connection path is installed rather than
    offering a control that would fail;
24. manufacturer, model and firmware appear where they belong, and identifiers
    stay masked until revealed;
25. the page does not hang while a modem's ports are being resolved, which is
    the user-visible half of the laziness rule;
26. the console is clean.

## Release gate

`sh scripts/verify.sh`, the official OpenWrt SDK build with APK inspection, the
package lifecycle matrix with two modems already attached, the hardware gate
above, then publication and the signed-feed smoke without `--allow-untrusted`.

The smoke must clear the exact-version constraints the local installs write, per
[`development-handoff.md`](development-handoff.md), and confirm what landed with
`apk list -I` rather than trusting the exit status.

No backend is promoted to `hardware` on fixture evidence, and each reset method
carries its own. A method that could not be exercised on this board ships
`synthetic` and says so.
