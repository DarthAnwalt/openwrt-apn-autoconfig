# 0.10.1 lock-protocol patch test and release plan

Status: synthetic, SDK, APK-inspection, upgrade and hardware gates complete.
Publication and the live signed-feed smoke remain open. Hardware evidence is in
[`router-test-0.10.1.md`](router-test-0.10.1.md).

0.10.1 is primarily a defect fix. It replaces the protocol that publishes an
operation lock, which the hardware-validated 0.10.0 reset path depends on. The
0.10.0 hardware evidence therefore does **not** carry over: the reset and
`BTN_0` paths must be re-proven on the router before this patch is called
stable.

It is not purely behaviour-preserving. The release also carries the first
runtime step of 0.11.0 — the read-only `provision-plan` query and the exclusion
of disabled project-owned sections from the APN engine's `auto` selection — 
because those were built into the binaries that passed the hardware gate.
Splitting them out afterwards would have invalidated that evidence. Both are
listed explicitly in the changelog; the `auto` change is the only one that
alters existing behaviour, and it cannot affect any released configuration
because no released version creates the ownership markers it keys on.

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

## Completed SDK gate

GitHub Actions run `31824195430` on PR 29 (`fix/0.10.1-lock-protocol`) passed
`scripts/verify.sh` and the official OpenWrt 25.12.5 SDK build, and produced all
five packages. Downloaded checksums verified against the run's `SHA256SUMS`:

| Package | SHA-256 |
|---|---|
| `apn-autoconfig-0.10.1-r1.apk` | `a8c2e814117f11ded412978d2ad12046e1dcfb790fead8173c62827d0125596a` |
| `apn-autoconfig-modem-0.10.1-r1.apk` | `e0d055fc83489fdea299b319f79c6d1b9bc413b6ce1d6d4c3281e89238ddff8c` |
| `apn-autoconfig-integration-huasifei-wh3000-0.10.1-r1.apk` | `0d4210e2fce0f012e1e0979c84fa9b6bd82ad42af00f98f6840c0cd84e671236` |
| `apn-autoconfig-providers-2026.08.10-r1.apk` | `8910b2f83fe0fa972828f2160ada06d3950d039bc25c7520b6b3b6123fbe38c7` |
| `luci-app-apn-autoconfig-0.10.0-r1.apk` | `fb678176bdc7846964f761061e59bdc6032603dced27f386a71340100feb01a3` |

`luci-app-apn-autoconfig` stays at 0.10.0 because this patch does not change it.
The Huasifei integration is versioned by the root Makefile and therefore moves
to 0.10.1 with the core.

Package-name collisions were re-checked immediately before this candidate: the
official OpenWrt packages feed contains no `apn*` package, and no third-party
`apn-autoconfig` package is visible. 0.10.1 introduces no new package name, so
the namespace decision from 0.10.0 is unchanged.

APK contents were **not** inspected from the desktop: OpenWrt 25.12 produces apk
v3 ADB containers, and no apk v3 tool exists on the maintainer's macOS host.
Inspect the installed package on the router with the real `apk` instead, which
is stronger evidence than desktop unpacking because it covers what is actually
installed.

## Completed hardware and lifecycle gates

Recorded in [`router-test-0.10.1.md`](router-test-0.10.1.md): APK inspection with
the real apk v3 tool on the router, the live 0.10.0-to-0.10.1 upgrade with
conffiles preserved, the compatibility reset, a `TERM` inside the destructive
window, the `BTN_0` duplicate-release invariant (three releases, one power-cycle,
one terminal result), the re-measured wall-clock bound and the removal
simulation.

## Open gates before release

1. Publication of the release tag and the signed feed.
2. The live feed install/removal/reinstall smoke without `--allow-untrusted`.

## Upgrade constraint

A running 0.10.0 process still uses the two-step protocol. The new code honors a
live 0.10.0 lock and reclaims a dead one, but mixed binaries against one shared
lock are not a supported steady state. Upgrade `apn-autoconfig` and
`apn-autoconfig-modem` together.
