# 0.10.1 lock-protocol patch test and release plan

Status: synthetic gate complete; SDK, lifecycle and hardware gates open.

0.10.1 changes no feature and no public API. It replaces the protocol that
publishes an operation lock, which the hardware-validated 0.10.0 reset path
depends on. The 0.10.0 hardware evidence therefore does **not** carry over: the
reset and `BTN_0` paths must be re-proven on the router before this patch is
called stable.

## What changed

See `docs/modem-contract-v1.md`, section "Lock representation". A lock is now a
regular file whose first line is the owner PID, published atomically with `ln`.
The previous `mkdir`-then-write sequence left a window in which the lock existed
with no recorded owner, and every waiter treated a missing owner as proof of a
crash.

Both defects this fixes were found as intermittent failures of `scripts/verify.sh`
itself, not on hardware:

- `parallel action-start accepted 2 workers instead of exactly one`;
- `background reset action ended in state 'failed'`, message
  `background worker stopped unexpectedly`.

## Completed synthetic gate

`sh scripts/verify.sh` passes, including the released 0.9.2 and 0.10.0
regressions. New behavioral cases in `tests/run-tests-modem.sh`:

- a start lock owned by a live process is never stolen, and its recorded owner
  is not overwritten;
- repeated parallel launches accept exactly one worker on every round, rather
  than asserting the invariant once;
- the launcher-to-worker handoff is reported `busy`, while a worker that really
  died without a start lock still reaches a terminal `failed`;
- a 0.10.0 directory-style identity lock is honored while its owner lives and
  reclaimed once it dies, with no deadlock against the old representation;
- a hotplug debounce marker left by a dead worker does not disable later
  rescans;
- contention on the shared APN lock exits in the retryable class, touches
  neither the interface nor the GPIO, and does not steal the lock.

The parallel-launch case was previously flaky in both directions; it passed the
loaded soak described below only after the fix.

### Soak evidence

The two defects appeared roughly once per four to eight runs of the modem suite
on a loaded host. Re-run the suite under sustained CPU load, not once on an idle
machine — a single green run proves nothing about either defect.

## Open gates before release

1. Official OpenWrt 25.12 SDK build of `apn-autoconfig` and
   `apn-autoconfig-modem`, and inspection of the produced APKs.
2. Clean install, 0.10.0 upgrade and removal simulation, including the
   `postrm` path that now understands both lock representations.
3. Live 0.10.0-to-0.10.1 upgrade on the WH3000 with the modem attached.
4. Hardware re-validation of the reset path, because its lock protocol changed:
   - compatibility `apn-autoconfig modem-reset` completes, GPIO returns to its
     powered-on value, both locks are clear and connectivity is verified;
   - a real `TERM` during the destructive window still restores power, the
     selected interface and both locks;
   - one `BTN_0` release starts exactly one operation, and a second release
     during that operation is logged as an ignored duplicate — this is the
     window the handoff defect corrupted, so it must be exercised deliberately
     rather than assumed;
   - `modem_wait_seconds` is now a wall-clock bound; record the observed
     power-restored-to-owner-returned duration again and confirm it is bounded
     by the configured value.
5. Signed-feed publication and the install/removal/reinstall smoke test.

## Upgrade constraint

A running 0.10.0 process still uses the two-step protocol. The new code honors a
live 0.10.0 lock and reclaims a dead one, but mixed binaries against one shared
lock are not a supported steady state. Upgrade `apn-autoconfig` and
`apn-autoconfig-modem` together.
