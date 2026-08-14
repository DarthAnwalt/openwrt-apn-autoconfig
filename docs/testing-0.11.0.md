# 0.11.0 first-run provisioning test and release plan

Status: contract accepted, implementation in progress. No hardware gate has
been attempted.

Implemented and covered so far: `provision-plan` with its stable refusal
reasons; the `auto`-selection protection for disabled project-owned sections;
the borrowed operation lock in both directions; and `provision` /
`deprovision` including the staging section, ownership markers, promotion,
the provisioning baseline, exact rollback and interruption.

Still to implement: the manual APN path, the LuCI first-run view, the
install/upgrade/removal lifecycle tests, and a narrow engine-owned way to
forget a deprovisioned target's state (see below).

The provisioning path has had one exploratory hardware run, recorded in
[`router-test-0.11.0.md`](router-test-0.11.0.md): refusal paths, provisioning,
promotion, the `auto`-selection protection and teardown all behaved correctly
on the WH3000. It was run from `/tmp` against the installed 0.10.1 packages,
so it validates the code, not a 0.11.0 package. `connect`/`disconnect`/
`reconnect`, interruption and concurrency remain fixture-only.

**Known gap from that run:** `deprovision` leaves the APN engine's per-target
state behind. `apn-autoconfig reset --target` cannot be used to clear it as
things stand, because its no-baseline path runs `rm -rf "$CACHE_DIR"` against
a cache shared by every target. This needs a narrow engine operation, not a
reach into the engine's state from the modem package.

The test harness's `uci` mock now supports `set`, `delete`, `commit` and
`revert`, and journals every write. Assertions therefore check which keys were
written, not just the resulting state — which is what makes "touched only the
section it created" a real assertion rather than an inspection.

0.11.0 builds directly on the locks repaired in 0.10.1 and adds new callers to
them. Land and validate 0.10.1 first; do not develop provisioning against the
0.10.0 lock protocol.

## In scope

Per [`roadmap.md`](roadmap.md) and [`provisioning-contract-v1.md`](provisioning-contract-v1.md):

- a capability-driven first-run workflow for an unconfigured ModemManager or QMI
  modem;
- creation of only a disabled, project-owned staging netifd section;
- automatic and manual APN paths, both through the existing APN engine;
- connection through netifd, real Internet verification, then promotion of the
  requested autoconnect state;
- basic connect/disconnect/reconnect;
- explicit adoption rules — in v1, no adoption at all; and
- exact provisioning rollback and removal tests.

## Explicitly out of scope

- adoption or rewriting of user-created sections;
- native MBIM profile mutation (0.12.0);
- generic writable AT control (0.13.0);
- Fibocom dial protocol (0.14.0);
- eSIM operations (0.15.0); and
- removal of the released APN CLI compatibility shims.

## Contract tests before implementation

Define fixtures and assertions for each of the following before the
corresponding runtime code is written. Prefer executable fixture assertions over
grepping for implementation text.

### Preconditions and fail-closed behavior

1. zero, one and multiple candidate modems for `--modem`;
2. an ambiguous record and a `conflicting` owner state each refuse to provision
   and perform no UCI write;
3. a modem already bound to a netifd interface refuses with
   `already_configured` and never rewrites that interface;
4. an unsupported protocol (`mbim`, `at`) is recognised and refused, not
   silently treated as QMI;
5. failed or unparseable owner discovery blocks provisioning exactly as it
   blocks a reset;
6. `provision-plan` performs no UCI write, creates no state and opens no control
   channel, for every one of the above outcomes.

### Ownership and naming

7. a section missing any of the three ownership markers is never modified,
   promoted, disabled or deleted, including one that otherwise looks exactly
   like a section this package would create;
8. `apnmodem<N>` selects the lowest free index, and a name that appears between
   selection and write aborts without mutation;
9. re-running `provision` for a modem that already has a project-owned section
   returns the existing section instead of creating a second one;
10. the markers survive an interface restart and a `uci commit` by an unrelated
    package.

### Staging safety

11. the created section has `disabled=1`, `auto=0` and **no** `apn` option, so
    netifd cannot dial a default APN before reconciliation;
12. no other `network` section, and no `mwan3`, Travelmate, firewall or routing
    configuration, is modified at any step;
13. a disabled project-owned section is excluded from the APN engine's `auto`
    target selection, while an explicit `--target` still selects it, and a
    promoted section participates in `auto` normally. This case protects an
    already working modem from a second provisioning attempt.

### Locks and composition

14. provisioning takes the global APN lock, then the per-modem lock, and
    releases them in reverse order;
15. `apn-autoconfig` accepts a borrowed operation lock only when the global
    lock's recorded owner is exactly the given live PID; a stale PID, a
    mismatched PID and a bare environment variable are all refused;
16. a borrowed lock is never released by the borrower;
17. provisioning and a reset for the same modem cannot overlap, and two
    simultaneous `provision` launches accept exactly one worker;
18. an externally started operation is detected and reported busy.

### Rollback and interruption

19. failure at each step — section creation, interface up, reconciliation,
    connectivity verification, promotion — removes exactly the section that was
    created and nothing else;
20. a real `TERM` during the destructive window restores the prior
    administrative state, removes the staging section and releases both locks in
    reverse order;
21. when the APN engine has already written profile fields before a later
    failure, its rollback restores those fields and provisioning then removes
    its section; neither reaches into the other's fields;
22. rollback never deletes a section whose ownership markers do not match.

### Lifecycle

23. install, offline image-root install, upgrade from 0.10.1 and removal, each
    with a modem already present;
24. `postrm` removes provisioning state but leaves project-owned sections
    working, since netifd owns the bearer;
25. `deprovision` removes the section and its state exactly, and refuses a
    section that is not project-owned.

## Hardware gate

Nothing below has been attempted. The WH3000 currently has a working,
pre-existing `wwan` target, so first-run provisioning must be proven without
disturbing it.

1. Snapshot the router configuration and capture a recovery bundle first.
2. Prove that `provision-plan` reports `already_configured` for the existing
   production modem and performs no write.
3. Prove the `auto` selection protection: with a staging section present, the
   existing APN operations on `wwan` continue to select the same target.
4. Provision a genuinely unconfigured modem, through staging, reconciliation,
   connection and promotion, and verify real Internet access through the new
   interface's effective route.
5. Interrupt a provisioning run with `TERM` during the destructive window and
   confirm exact rollback with `wwan` untouched.
6. `deprovision` and confirm the router returns to its captured baseline.
7. Re-run the complete 0.10.1 reset and `BTN_0` matrix afterwards to prove
   provisioning did not regress the validated reset path.

## Release gate

As for 0.10.0 and 0.10.1: official OpenWrt 25.12 SDK build, APK
install/upgrade/removal simulation, live/offline service behavior, signed-feed
publication without a trust bypass, `sh scripts/verify.sh`, and preserved CI
checksums, package inventory and redacted hardware logs.

Do not mark any provisioning path `stable` or `hardware_validated` on the
strength of the fixture suite. Runtime capability, implementation maturity and
validation evidence stay separate fields.
