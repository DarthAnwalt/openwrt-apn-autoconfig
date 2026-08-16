# 0.14.0 AT test and release plan

Status: planned. No implementation has started and no evidence has been
recorded.

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
- the mandatory AT port lock as the innermost level of the existing order;
- `/usr/libexec/apn-autoconfig-at`: identity only, per the backend contract;
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
9. the same holds with no external `timeout` on `PATH`, exercising the watchdog;
10. the watchdog terminates and reaps its child, leaving no process behind,
    asserted against the process table rather than inferred;
11. a timed-out port is not retried with an alternate ICCID spelling, while a
    port returning an immediate command error is;
12. a `TERM` during a probe releases the port lock and leaves no scratch file.

### Lock

13. two concurrent identity requests for one port serialize, and neither
    proceeds without the lock;
14. two concurrent requests for *different* ports do not serialize against each
    other at this level;
15. a lock whose owner is dead is reclaimed only under the `.reclaim` guard,
    reusing the existing shared assertions;
16. the AT adapter and the QMI adapter's AT fallback contend on one device and
    exactly one proceeds at a time.

### Identity

17. the v1 identity TSV is complete and well-formed from a fixture modem;
18. `operator_id` is empty and the matcher still selects the right provider from
    the IMSI prefix, for both a five-digit and a six-digit database row;
19. `<stat>` 3 maps to denied and is reported as permanent, not retryable;
20. `AT+CSQ` 99 leaves `signal_quality` empty rather than reporting zero;
21. malformed, truncated and echo-polluted replies fail closed rather than
    yielding a partial identity;
22. an ICCID of implausible length is rejected, reusing the existing digit
    validation.

### Reset methods

23. each of `gpio`, `modemmanager` and `at` is selected exactly when its
    preconditions hold, and `reset_method` reports it;
24. `gpio` wins where its preconditions hold, preserving released behaviour;
25. a second modem on the same board does not inherit the pinned modem's GPIO
    reset;
26. a soft reset whose port disappears without a final `OK` is treated as
    success pending re-enumeration, not as a transport failure;
27. a soft reset whose modem never returns is a terminal failure with the
    correct class, distinguishable from 26;
28. a real `TERM` during the destructive window restores the interface and
    releases both locks in reverse order;
29. `capabilities.reset` true never implies any method has been observed to
    work.

### Compatibility

30. `apn-autoconfig modem-reset` and `action-start modem-reset` keep their
    released behaviour and exit codes on the pinned GPIO modem;
31. a v1 consumer that ignores the new schema fields behaves exactly as before;
32. no command leaves a scratch file in `/tmp`, extending the 0.13.2 regression
    to the new commands.

## Hardware gate

The reference router carries the internal RM520N-GL in its M.2 slot, owned by
ModemManager and resettable through the Huasifei GPIO. For this gate an FM350-GL
in a USB carrier is attached alongside it, giving both control-owner classes and
both reset methods on one board at the same time.

### First contact, recorded before anything else

1. what the FM350 enumerates as: VID:PID, USB composition, whether the carrier
   introduces a hub level in `usb_path`, which network device appears and under
   which driver;
2. how many tty nodes it exposes, and for each: whether it answers bare `AT`,
   whether it answers `AT+CGMM`, and what it returns;
3. the same census for the RM520N, for comparison against the port the QMI
   adapter's existing AT fallback already selects.

These facts are needed for 0.15.0 regardless of how this release turns out, so
they are captured even if a later step fails.

### Two modems at once

4. both modems appear in inventory with distinct `modem_id`s and
   `ambiguous: false`;
5. neither record borrows the other's `at_device`, `control_device` or
   `data_device`, checked against the census above rather than assumed;
6. the RM520N reports `owner_state: modemmanager` and receives no AT probe at
   all, verified from the router's own process/serial activity, not only from
   our logs;
7. the FM350 resolves exactly one AT port by role and yields a complete
   identity;
8. its identity matches the correct provider from the database with
   `operator_id` empty;
9. an APN operation on one modem reports the other as busy — the deferred
   global-lock behaviour, recorded here as expected so it is not filed as a
   defect.

### Reset

10. `modem-reset` on the RM520N selects `gpio`, behaves exactly as released, and
    the FM350 is unaffected throughout;
11. `modem-reset` on the FM350 selects `at`, and the vanished port during
    `AT+CFUN=1,1` is reported as success pending re-enumeration;
12. after that reset the FM350 returns with the same `modem_id`, even if its tty
    indices changed;
13. **the neighbouring modem survives the renumbering**: if the kernel reassigns
    tty indices across the re-enumeration, the RM520N's record still resolves to
    its own ports and its own identity. This is the headline test of the
    "names are attributes, not identity" invariant;
14. `modem-reset` on the RM520N with ModemManager stopped, or a deliberate
    `mmcli --reset` run, covers the `modemmanager` method;
15. an interruption during the FM350 reset leaves the interface and both locks
    restored.

### Optional window: netifd-direct QMI

16. with ModemManager stopped and the RM520N raised as a native QMI target, the
    record reports `owner_state: netifd-direct`, AT resolution is now permitted
    on it, and `reset_method` becomes `at`.

This step needs a deliberate configuration change on a live router and must be
scheduled and reverted explicitly, as the MBIM composition switch was in 0.12.0.
Without it, `netifd-direct` AT ownership ships with fixture evidence only and
must be recorded as such.

### Browser pass

17. both modems appear, each with its identity, protocol, owner and
    `reset_method`;
18. the AT-only modem explains that no connection path is installed rather than
    offering a control that would fail;
19. manufacturer, model and firmware appear where they belong, and identifiers
    stay masked until revealed;
20. the console is clean.

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
