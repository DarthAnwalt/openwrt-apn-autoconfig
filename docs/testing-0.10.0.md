# 0.10.0 modem-control foundation test and release plan

Status: complete. Runtime hardening, synthetic tests, official SDK builds, live
0.9.2-to-0.10.0 upgrade, WH3000 hardware validation, release publication and
the live signed-feed install/removal/reinstall smoke all passed. See
`router-test-0.10.0.md`.

## Implementation status

`apn-autoconfig-modem` (read-only inventory, coordinator, bounded `reset`),
the `apn-autoconfig` compatibility shim, the LuCI read-only inventory card
and `tests/run-tests-modem.sh` are implemented and pass
`sh scripts/verify.sh`. Coverage against the contract-test list below:

- Covered: modem-record schema and 0/1/N candidates; USB-serial/IMEI/weak
  evidence; inventory-only QMI/MBIM/AT classification; ModemManager-first
  ownership without direct QMI probing, including failed ownership discovery;
  physical USB device-root correlation through the netifd `device` option used
  by the WH3000 runtime;
  QMI identity bounding without an external `timeout`; duplicate weak identity
  and duplicate netifd-binding ambiguity; multi-port AT-only failure versus
  optional AT-port suppression on proven QMI; all owner states including the live
  `transitioning` overlay; service-start scanning; hotplug debounce; strong
  board-reset binding; GPIO/interface/lock restoration under real `SIGTERM`;
  delayed original-owner return before netifd restoration; delayed primary-SIM
  readiness after coordinator return; bounded ModemManager calls with and
  without an external `timeout`, including orphan-free watchdog cleanup;
  atomic parallel action launch; v2 operation state; stale worker recovery;
  narrow RPC wrappers; and behavioral compatibility-shim success and failure
  propagation. All released 0.9.2 regressions remain green.
- Additional malformed-output and no-external-timeout backend permutations may
  be added if platform findings expose a new case; they are defense-in-depth,
  not open release blockers.
- Hardware-only evidence is recorded in `router-test-0.10.0.md`; it is not
  inferred from the synthetic suite.

Version 0.10.0 establishes the control plane required by provisioning, MBIM,
generic AT, Fibocom and eSIM milestones. Passing this plan proves the
architecture foundation and compatibility of released behavior. It does not
claim automatic network provisioning or native MBIM profile support.

## In scope

- package `apn-autoconfig-modem` with a documented versioned machine API;
- read-only inventory at service start, boot, hotplug and explicit rescan;
- stable project modem records and safe rebinding after re-enumeration;
- runtime capability, implementation and validation evidence kept separate;
- explicit ModemManager/direct-control ownership state;
- a common operation coordinator usable by modem reset and APN reconcile;
- migration of low-level identity/status/reset access behind the new boundary
  without changing released APN outcomes;
- common LuCI shell with read-only modem inventory and existing APN functions;
- compatibility shims for released APN CLI/RPC consumers; and
- unchanged Huasifei BTN_0 power-cycle followed by targeted APN reconciliation
  and connectivity verification.

## Explicitly out of scope

- automatic creation or adoption of netifd sections;
- native MBIM profile mutation;
- generic writable AT control or arbitrary AT terminal;
- Fibocom/FM350 dial protocol;
- eSIM profile operations or bundled lpac; and
- removal of released CLI compatibility shims.

## Contract tests before implementation

Define fixtures and assertions for:

1. modem-record schema, stable ID inputs and volatile device attributes;
2. zero, one and multiple candidate devices;
3. absent, late and malformed backend dependencies;
4. capability versus implementation/validation evidence;
5. owner states `none`, `netifd-direct`, `modemmanager`, `transitioning` and
   unsupported/conflicting ownership;
6. bounded retryable discovery versus terminal unsupported/ambiguous results;
7. hotplug coalescing and idempotent repeated reconcile;
8. operation IDs, per-modem serialization, terminal result persistence and
   safe composition with APN reconcile; and
9. compatibility mapping to released APN target/status/action responses.

No fixture may select a device by first enumeration order, infer write support
from a protocol label or mutate UCI during read-only inventory.

## Installation-order and lifecycle matrix

Each row must converge to the same inventory for the same hardware state:

| Scenario | Required result |
|---|---|
| Modem present before live package installation | Service-start scan finds it without reconnecting hardware |
| Package installed before modem attachment | Hotplug schedules the same reconcile and record |
| Internal modem present at router boot | Delayed readiness handles services/drivers appearing in either order |
| Service stopped while modem is attached | Next service start finds current state without event replay |
| Driver/backend installed after modem-control | Backend/package event or explicit rescan upgrades capability truthfully |
| Modem re-enumerates with new `/dev` names | Strong identity rebinds attributes without creating a second record |
| Weak identity or two equal candidates | Inventory reports ambiguity and performs no mutation |
| Existing user-created netifd section | It is observed but never silently adopted or rewritten |

Offline root/image installation must not attempt ubus, sysfs discovery or UCI
provisioning. Package hooks may enable/start the live service; runtime code owns
all scanning.

## Ownership and concurrency tests

- Direct QMI/MBIM/AT operations do not run against a ModemManager-owned modem.
- Read-only inventory does not restart ModemManager, netifd or another modem.
- One modem's operation does not block an unrelated modem unless an explicitly
  documented global resource requires it.
- Duplicate CLI, LuCI, boot, hotplug or button triggers coalesce or return busy;
  they never overlap the same modem mutation.
- Interruption leaves a terminal/retryable operation record and releases every
  lock without allowing a stale worker to mutate later.
- A reset-plus-reconcile composite cannot deadlock through nested locks.

## Released APN regression gate

All existing 0.9.2 fixture tests remain green. On supported existing targets:

- ModemManager and QMI identity/profile behavior is unchanged;
- exact baseline, connectivity verification and rollback are unchanged;
- read-only commands remain read-only and bounded;
- unavailable/ambiguous targets still fail closed;
- LuCI and CLI retain their current target and result semantics; and
- package removal can still restore every baseline created before upgrade.

Upgrade testing must include persisted 0.9.2 UCI, per-target baseline/cache and
action state. No migration may relabel a user-created interface as project-owned.

## Huasifei hardware gate

On the tested Huasifei WH3000 Pro setup, prove both manual and physical paths:

1. install/upgrade the board integration and keep it disabled by default;
2. run the compatibility `modem-reset` command through the new coordinator;
3. confirm only the selected target stops;
4. confirm the guarded GPIO returns to its powered-on value after success and
   after interruption;
5. wait boundedly for the same modem to re-enumerate under changed volatile
   device/object indices, for its original control owner to reclaim it and for
   the primary SIM to become readable;
6. reconcile a changed or unchanged SIM/APN as appropriate;
7. verify real Internet connectivity and online mwan3 state where installed;
8. confirm `BTN_0` press is ignored and one enabled release queues exactly one
   identical composite operation;
9. confirm repeated releases cannot overlap; and
10. confirm LuCI reports the externally started operation and terminal result.

The release fails if the button merely power-cycles the modem without APN
reconcile, if it needs a manual USB reconnect, or if it resets an unrelated
interface/modem.

## LuCI and privacy gate

- The common shell distinguishes modem/connection information from APN policy.
- Inventory remains useful when a modem lacks a writable backend.
- Controls appear only for advertised capabilities; missing packages produce
  an explanation rather than a failing button.
- ICCID, IMSI and EID remain masked until explicit reveal.
- Operations started outside LuCI stay busy until a valid terminal status is
  observed; polling loss never invents success.
- RPC allowlists expose fixed operations and validated identifiers only.

## Packaging and release gate

- Build all first-party 0.10.0 code packages with the official supported SDK.
- Simulate and execute clean install, 0.9.2 upgrade and removal transactions.
- Verify service behavior in live install and offline image-root contexts.
- Verify removal preserves live operation locks and cleans only stale runtime
  state; it must not use a wildcard that can erase an in-flight lock.
- Check package names against supported OpenWrt indexes and known public
  package trees immediately before the release candidate.
- After the release tag publishes the signed project feed, install exclusively
  through that live feed without `--allow-untrusted` and complete the final
  removal/reinstall smoke test.
- Run `sh scripts/verify.sh` and preserve CI checksums, package inventory,
  hardware logs with private identifiers redacted and recovery artifacts.

## Exit criteria

All 0.10.0 exit criteria are met: read-only discovery is independent of package
and modem attachment order, ownership conflicts fail closed, the coordinator
cannot overlap same-modem mutations, all 0.9.2 APN behavior remains compatible,
the complete Huasifei reset-plus-reconcile path passed on hardware and the
published signed-feed lifecycle completed without a trust bypass.
