# Provisioning contract v1 (0.11.0)

Status: accepted design for 0.11.0. `provision-plan`, `provision`,
`deprovision`, `connect`, `disconnect` and `reconnect` are implemented and
covered by fixtures; the manual APN path and the LuCI first-run view are not,
and nothing here has run on hardware. This document is normative for
`apn-autoconfig-modem`'s provisioning API. It extends
[`modem-contract-v1.md`](modem-contract-v1.md) and inherits every rule in it,
including the lock representation and lock ordering. The safety invariants in
[`architecture.md`](architecture.md) remain binding.

Provisioning is the transition from a **discovered** modem to a **connected**
one. 0.10.0 deliberately stopped at discovery; this contract defines the
smallest safe step past it.

## Scope

In scope for v1:

- create a disabled, project-owned staging netifd section for exactly one
  unambiguous, unconfigured modem;
- run targeted APN reconciliation against that section through the existing APN
  engine, never by writing profile fields directly;
- connect through netifd, verify real Internet access, and only then promote the
  requested autoconnect state;
- basic `connect` / `disconnect` / `reconnect` on a project-owned section;
- exact rollback of everything provisioning created; and
- removal of project-owned provisioning state without touching anything else.

Out of scope for v1: adoption of user-created sections, MBIM profile mutation,
eSIM, Fibocom dial protocol, multi-bearer policy, and any mutation of `mwan3`,
Travelmate, firewall or routing configuration.

## Ownership

A section created by this package carries three markers in `network.<section>`:

| Option | Value |
|---|---|
| `apn_autoconfig_owner` | `apn-autoconfig-modem` |
| `apn_autoconfig_modem_id` | the stable `modem_id` it was provisioned for |
| `apn_autoconfig_provisioned` | UTC ISO-8601 timestamp of creation |

These are the authoritative ownership record. A section without all three is
**not** project-owned and is never modified, promoted, disabled or deleted by
provisioning, regardless of how closely it resembles one this package would
create. netifd ignores unknown options, so the markers are inert at runtime.

`apn-autoconfig` continues to own only the declared APN/profile fields of the
selected target and its own baseline state. Provisioning owns the section's
existence, `proto`, `device`/`devpath`, `disabled` and `auto`. netifd remains
the sole bearer owner. Neither package writes the other's fields.

### Adoption

There is no adoption in v1. A modem already bound to any netifd interface is
not provisionable; `provision` fails closed with `already_configured`. Adoption
requires a recorded ownership decision and is deferred to a later milestone.

## Section naming

The section name is `apnmodem<N>`, with `N` the lowest positive integer whose
name is not currently present in `network`. The name is chosen inside the
operation locks and re-checked immediately before the write. If the chosen name
exists at write time, the operation aborts without mutation rather than picking
another; a caller retries.

A name that exists and is project-owned for the *same* `modem_id` is not a
collision: it is the existing provisioning for that modem, and `provision`
returns it unchanged rather than creating a second one.

## Preconditions

`provision` proceeds only when **all** hold, revalidated after both locks are
held:

1. exactly one inventory record matches `--modem`, and it is present;
2. `ambiguous` is false and `owner_state` is not `conflicting`;
3. `netifd_interface` is empty — the modem is not already bound;
4. the modem's protocol has an implemented provisioning path (`qmi` or
   `modemmanager` in v1; `mbim` and `at` are recognised but refused);
5. the required control/data attributes for that protocol are resolved and
   unambiguous; and
6. the chosen section name is free.

Any failure is terminal and performs no mutation. Uncertainty is not permission:
a failed or unparseable owner discovery blocks provisioning exactly as it blocks
a reset.

## States

A project-owned section is in exactly one state, derived from configuration and
runtime rather than stored as a separate field:

| State | Meaning |
|---|---|
| `staged` | created, `disabled=1`, no APN applied yet |
| `reconciled` | an APN profile has been applied by the APN engine |
| `connected` | netifd reports the interface up and connectivity is verified |
| `promoted` | the requested autoconnect state has been applied |
| `failed` | the last provisioning operation failed; staging state still present |

`staged` never dials. The section is created without an `apn` option and with
`disabled=1` precisely so netifd cannot attempt an empty or vendor-default APN
before reconciliation chooses one.

This is also why provisioning must never call `ifup` itself. Clearing
`disabled` only makes the section startable; `auto=0` keeps netifd from
starting it on an unrelated reload, and the APN engine performs the actual
bring-up after it has written a profile. Starting the section between those two
points would produce exactly the APN-less dial the staging rules prevent.

## Workflow

`provision` is one serialized composite operation:

1. acquire the global APN operation lock, then the per-`modem_id` lock;
2. revalidate presence, identity, capability, owner and section-name freedom;
3. capture and atomically persist the provisioning baseline (below);
4. create the staging section with `proto`, the resolved device binding,
   `disabled=1`, `auto=0` and the three ownership markers; `uci commit network`;
5. clear `disabled` so the section can be started, but **do not start it here**;
6. run targeted APN reconciliation by invoking
   `apn-autoconfig reconcile --target network:<section>` with the borrowed
   operation lock (below); the APN engine owns matching, application,
   connectivity verification, interface bring-up and profile rollback;
7. verify connectivity through the selected target's effective L3 route;
8. apply the requested autoconnect state (`auto=1` unless the caller asked
   otherwise) only after step 7 succeeds; and
9. release the modem lock, then the global lock.

Failure at any step runs the rollback below and returns a terminal result.

## Borrowed operation lock

Provisioning inverts the existing borrow direction. In 0.10.0 the APN engine
owns the global lock and `apn-autoconfig-modem` borrows it for a reset. Here
`apn-autoconfig-modem` owns it and the APN engine borrows it for reconciliation.

`apn-autoconfig` therefore accepts `APN_AUTOCONFIG_LOCK_OWNER_PID`, mirroring
the existing `APN_AUTOCONFIG_COORDINATOR_PARENT_PID`: the lock is treated as
held only when the global lock's recorded owner is exactly that PID and that
process is alive. A borrowed lock is never released by the borrower. Presence of
the environment variable alone is not ownership.

This keeps one global order — global APN lock, then per-modem lock — in both
directions and avoids a component holding a lock while synchronously waiting for
another component that would try to acquire it.

## Baseline and rollback

Before the first write, provisioning persists a baseline record under
`/var/run/apn-autoconfig-modem/provisioning/<sanitized modem_id>.tsv` with
`umask 077`, containing a schema version, the operation ID, the `modem_id`, the
chosen section name, and whether that section existed beforehand (it must not).

Rollback is exact and bounded:

- if provisioning created the section and the operation fails at any later step,
  bring the interface down, delete **only** that section, `uci commit network`,
  and remove the baseline;
- never delete or rewrite a section whose ownership markers do not match;
- never touch another interface, `mwan3`, Travelmate, firewall or routing;
- restore the powered/administrative state exactly as before the attempt; and
- arm the rollback before the first mutation, and run it on failure and on
  `HUP`/`INT`/`TERM`, in reverse order of acquisition.

If the APN engine already wrote profile fields before a later failure, its own
baseline and rollback restore those fields; provisioning removes the section it
created afterwards. The two rollbacks compose in that order and neither reaches
into the other's fields.

## Effect on `auto` target selection

Creating a second cellular section would otherwise make the APN engine's `auto`
target selection ambiguous and break APN operations on an already working modem.
`apn-autoconfig` therefore excludes **disabled project-owned** sections from
`auto` discovery. A section that has been promoted participates normally. An
explicit `--target network:<section>` always selects the named section, whether
disabled or not.

## Machine API

All responses are single-line JSON with `"version":"v1"`. Exit classes match the
existing coordinator: `0` success, `2` usage, `3` retryable (busy, temporarily
unavailable), `4` blocked (capability, identity, ownership or precondition).

```text
apn-autoconfig-modem provision-plan --modem <id>
apn-autoconfig-modem provision --modem <id> [--autoconnect 0|1] [--apn <name> ...]
apn-autoconfig-modem deprovision --modem <id>
apn-autoconfig-modem connect|disconnect|reconnect --modem <id>
apn-autoconfig-modem action-start provision --modem <id>
```

`provision-plan` is strictly read-only. It reports whether the modem can be
provisioned, the section name that would be created, the protocol that would be
used, and, when it cannot, a stable machine-readable reason:
`already_configured`, `ambiguous`, `conflicting_owner`, `unsupported_protocol`,
`not_present`, `name_unavailable`. It never writes UCI, never creates state and
never opens a control channel beyond the existing bounded inventory scan.

The manual APN path passes profile fields through to the APN engine's manual
profile operation. Provisioning never writes `apn`, `username`, `password`,
`auth` or `pdptype` itself; those remain APN-engine-owned fields applied through
the same baseline, verification and rollback discipline as a database profile.

## Removal

Package removal must not silently delete a user's working connection. `postrm`
removes provisioning **state** only. Project-owned sections are left in place
unless the administrator ran `deprovision` first, and the removal notes say so.
A section whose markers identify it as project-owned remains functional after
removal because netifd, not this package, owns the bearer.
