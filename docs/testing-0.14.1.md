# 0.14.1 test plan and evidence

A defect-only patch. The plan is short because the release changes signal
handling and cleanup rather than behaviour anyone configures, but it still needs
a hardware gate: 0.14.0's gate found three defects no fixture could produce, and
this one found a fourth.

## What had to be proven

1. the scratch leak is gone on the paths that produced it;
2. an interrupted mutation rolls back completely — section, locks, power, state;
3. the sweep removes a dead run's files and nothing else;
4. the released reset behaviour is unchanged;
5. both modems remain discoverable throughout.

## Fixture and CI evidence

`sh scripts/verify.sh` green. CI is the authoritative run: it executes both LuCI
suites and the official OpenWrt 25.12.5 SDK build, neither of which runs on the
maintainer's machine.

The SIGPIPE regressions need an interpreter where an untrapped SIGPIPE is fatal.
They are guarded by a probe rather than by a shell name, because on any host
whose `/bin/sh` is bash — every macOS — such a test passes against the exact code
it exists to reject. Two things were learned about that guard:

- **CI could not run these tests at all.** GitHub Actions runs steps from a
  parent that has SIGPIPE set to `SIG_IGN`; an ignored disposition survives
  `exec`, and POSIX forbids a shell from un-ignoring a signal that was already
  ignored when it started, so `trap - PIPE` cannot undo it from inside. Every
  candidate shell therefore looked non-fatal for a reason that had nothing to do
  with the shell. The disposition is now reset in a helper that execs the shell.
- **The guard is not weakened by that helper.** bash is still rejected through
  it, and with the `PIPE` trap deleted the regressions still fail under an
  ignoring parent.

## Hardware evidence

Reference router, OpenWrt 25.12.5, both modems attached at once: the internal
Quectel RM520N-GL and a Fibocom FM350-GL on USB. Packages installed as an
upgrade over 0.14.0, not through `apk del`, so the `reset_modem_id` pin survived
— confirmed present afterwards.

**The defect, reproduced before the fix.** Six ordinary commands against a closed
reader left 15 scratch files on 0.14.0. Two of them were `.mm-identity` and
`.mm-indexes` — the suffixes 0.14.0 added, and precisely the ones this fix's
original seven-entry list would have missed. After upgrading, the first run of
each binary swept them: 12 by the coordinator, 3 by the engine, with the four
unrelated `.apk` files in `/tmp` untouched. Repeating the same six commands on
0.14.1 left nothing.

**An interrupted mutation rolls back.** `provision` against a reader closed on
both stdout and stderr exited 141, left no section, no uncommitted UCI change, no
baseline, no locks and no scratch files, and did not disturb the other modem's
interface.

**The sweep removes only what it can prove is dead.** A dead PID's files were
removed across every suffix including the AT-era ones; a live PID's file, a
non-PID name, a suffix the coordinator never creates, a planted directory, a
planted symlink and that symlink's target all survived.

**Released reset is unchanged.** `action-start reset` on the pinned RM520N-GL was
accepted, ran 48 seconds and reported `state: success`, `exit_code: 0`. Both
modems were present before and after, with no scratch files and no leftover
locks.

## The defect this gate found

Interrupting a provision logged `failed to remove staging section apnmodem1`
while leaving nothing behind at all.

The rollback is armed *before* the staging section is written, which is the order
this project requires: an interruption in that gap must not find the cleanup
disarmed. Trapping `PIPE` made the gap reachable for the first time, and the
first log line after arming is exactly what takes the signal — so the rollback
ran with the section still unwritten, and `uci delete` reported the failure of
something that was never needed. State was always correct; the message sent an
operator looking for residue that did not exist.

Two fixture faults kept it invisible, and they matter more than the fix:

- the mock `uci` returned success for every `delete`, including of a section that
  does not exist, so no caller that treats "nothing to delete" as a failed delete
  could ever be caught;
- the mock reported every bare section name as absent, because `${section#*.}`
  on a name with no dot yields the name itself and no option ever matches it, so
  nothing could ask whether a section exists.

Both now behave as `uci` does. The regression reaches the same window
deterministically through a refused section creation instead of by racing a
signal, and the assertion also rides on the SIGPIPE test that mirrors the
hardware path.

## Still open after this release

- **The signed-feed smoke.** Deferred from 0.14.0 and carried into this cycle.
- **Whether a `><` world constraint blocks an upgrade the way `=` does.** Still
  unverified. It needs a moment where the pinned version is *older* than what the
  feed serves, and every hardware gate installs local artifacts, which re-pins to
  the version just tested. The handoff's check was corrected regardless: it
  looked for `=`, and the constraints actually recorded carry none.
- **LuCI page load time**, measured during this cycle at roughly four seconds of
  backend critical path. It is not waiting on hardware — `mmcli` answers in
  0.05 s. The inventory scan costs 448 external command invocations, and the page
  runs it 1+N times per load, once plus once per modem, because `provision-plan`
  rescans from scratch. 0.15.0.
- **Per-modem presentation in LuCI**, and the SIM-slot level beneath it that
  eSIM will need. 0.15.0 for the structure, 0.16.0 for eSIM itself.
