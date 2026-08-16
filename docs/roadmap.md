# Architecture roadmap

This roadmap records public release milestones. It describes intended outcomes,
not implementation proposals or evaluations of other projects. Hardware findings
may change the sequence, but the safety invariants in
[`architecture.md`](architecture.md) remain binding. Future milestones are not
claims about the released 0.10.0 packages.

The `apn-autoconfig` package keeps its narrow APN responsibility. The project
grows toward 1.0 through namespaced first-party packages for modem control,
provisioning, selected netifd protocols and eSIM lifecycle. The common LuCI
package consumes their versioned machine APIs. All packages are distributed
through the signed repository and built from source where applicable.

## 0.9.0 — adapter foundation

Released. Introduced stable target discovery, explicit capabilities, the
versioned GUI-independent API, per-target state, fail-closed mutation and the
complete ModemManager backend.

## 0.9.1 — native QMI adapter

Released. Added native QMI identity and profile handling for configured netifd
targets, exact rollback, dual-stack fallback and hardware evidence for the
Huasifei WH3000 Pro with Quectel RM520N-GL.

## 0.9.2 — rollback and backend hardening

Released. Hardened signal handling, QMI rollback, root-only state validation,
canonical device paths, baseline ownership, shared profile plumbing and QMI
data-interface readiness after a physical modem reset.

## 0.10.0 — modem-control architecture foundation

Released. Introduced `apn-autoconfig-modem` with read-only inventory at service
start and hotplug, stable modem identity, truthful capability evidence, explicit
ModemManager/direct-control ownership and a shared serialized operation model.
Moved low-level status and reset responsibilities behind its narrow API while
preserving the released APN commands as compatibility shims. Began the common
LuCI shell with modem inventory and the existing APN experience.

The release discovers a modem that was attached before package installation;
hotplug event history is not required. It preserves the tested Huasifei BTN_0
operation as one serialized modem power-cycle followed by re-enumeration,
targeted APN reconciliation and connectivity verification.
Automatic creation of network sections and MBIM profile mutation remain out of
scope until this foundation is proven.

## 0.10.1 — operation-lock correctness

Released. A defect-only patch with no feature or API change. It
makes lock publication atomic, so a lock can no longer be observed without a
recorded owner and deleted while it is live. That window allowed two background
workers to be accepted for one modem and made an accepted operation report
itself as a dead worker, which in turn made a duplicate physical button release
look like a rejected launch.

## 0.11.0 — safe first-run provisioning

Released. Added a capability-driven first-run workflow for an unconfigured
ModemManager or QMI modem: only a disabled, project-owned staging netifd
section, automatic and manual APN paths, connection through netifd, Internet
verification and only then promotion of the requested autoconnect state. Added
basic connect/disconnect/reconnect actions, explicit adoption rules — no
adoption of user-created sections — and exact provisioning rollback and removal
tests.

## 0.12.0 — complete native MBIM vertical slice

Released. Added MBIM inventory and ownership, safe network-section
provisioning, SIM and registration identity, backend-owned profile
capture/write/restore, dynamic IPv4/IPv6 readiness, connection control and
roaming policy over OpenWrt's `allow_roaming`/`allow_partner` pair. Hardware
evidence covers discovery through post-connect verification and rollback on a
modem switched into MBIM composition, not an isolated parser.

## 0.13.0 — coherent frontend

Released. Reorganized the optional LuCI package around the four things a user actually
reasons about — the modem, the APN policy, the SIM and the program's own
settings — instead of the order features were added in. A persistent status
strip keeps the target, its registration and the last result visible while the
areas themselves become tabs, so a failure is never hidden behind the tab a
user is not on. Manual APN entry moves behind a control into a dialog, because
it is the rare fallback rather than something the page should ask everyone to
fill in. Maintainer-grade evidence fields collapse under an explicit advanced
disclosure, and non-obvious fields gain short help opened by click rather than
hover, because touch devices have no hover.

Connection control stops depending on who created the interface. Operations
that change configuration — provisioning, removal and profile writes — stay
restricted to sections this project owns, but bringing a bearer up or down is
`ifup`/`ifdown`, which the APN engine already performs on user-created
interfaces during every reconcile. Refusing the button while performing the
action was inconsistent, and explaining the refusal read as the project's
convenience rather than the user's.

No machine API changes shape or meaning in this release.

## 0.13.1 — connection-control busy state

Released. A defect-only patch with no feature or API change. The connection
controls 0.13.0 introduced stayed clickable while an operation started from
another entry point held the shared lock, so the page offered a control that
could only fail and lost the double-click protection its other actions have.
The busy state is now symmetric in both directions.

## 0.13.2 — scratch-file cleanup

Released. A defect-only patch with no feature or API change. Two read-only
commands left a temporary file in `/tmp` on every run, so an open LuCI page grew
it without bound. The paths the exit trap removes are now assigned once at
start-up instead of inside a function reached through a command substitution,
where the assignment never reached the parent.

## 0.14.0 — AT identity backend and bounded AT transport

Add the third and last identity backend. A modem that answers 3GPP AT but
exposes neither QMI nor MBIM becomes identifiable, matchable against the
provider database and displayable. This is the precondition for the Fibocom
work that follows rather than a capability wanted for its own sake: an FM350 in
RNDIS composition exposes no `cdc-wdm` control node at all, so without this
release the suite could dial it in 0.15.0 and still have no way to choose an
APN for it.

The engineering content is port ownership rather than command vocabulary. The
release adds same-device AT-port resolution by observed role, a bounded
executor with a watchdog for images that have no external `timeout`, and a
mandatory AT-port lock in the shared lock protocol. Multiple AT ports inside
one proven USB device stop being terminal ambiguity — on a single modem they
are redundancy, resolved deterministically — while ambiguity between devices
still fails closed. A quirk table keyed by the modem's reported manufacturer
and model carries vendor divergence, and its default is empty: an untested
modem gets no capability rather than a guess.

`modem-reset` becomes one capability with several implementations, each chosen
by the modem's current control owner — the board GPIO power cycle where a
supported integration package pins the modem, ModemManager's own reset where
ModemManager owns it, and `AT+CFUN=1,1` where the project holds direct control.
Asking the legitimate owner to perform its own reset keeps the single-owner
invariant intact without an exception for any configuration. The released
Huasifei behaviour is unchanged; the operation stops being unavailable on
modems the board GPIO cannot reach. Automatic escalation between methods is
deliberately not part of this release.

Two modems present at once move from fixture coverage to hardware coverage.
While they do, the global APN operation lock stays system-wide, so operations
on two modems serialize against each other; see the deferred decision recorded
in [`architecture.md`](architecture.md).

No public control accepts free-form AT commands, and no AT path writes an APN
profile: profile fields remain UCI options applied by netifd, exactly as for
QMI and MBIM. Manual APN remains an APN-engine operation using the same
baseline, verification and rollback discipline as database profiles.

## 0.15.0 — Fibocom FM350 connection path

Add separately packaged netifd protocol support and capability modules needed
for the practical FM350 connection lifecycle. Validate provisioning,
connection, interruption, recovery and coexistence on hardware without moving
bearer ownership outside netifd.

## 0.16.0 — eSIM lifecycle and live APN recovery

Add `apn-autoconfig-esim` and, if still required, the private upstream-tracking
`apn-autoconfig-lpac` build. Provide protected activation-code handling,
bounded profile and notification operations, and the serialized workflow:
profile switch, optional capability-gated modem reset, refreshed SIM identity,
targeted APN reconcile and verified connectivity. Add the eSIM area to the
common LuCI package.

## 0.17.0 — 1.0 release-candidate hardening

Complete multi-modem, hotplug/re-enumeration, ownership coexistence, fresh
install, upgrade, removal and failure-recovery matrices. Revisit the two
correctness questions deliberately deferred earlier: whether the global APN
operation lock should gain per-target granularity, and whether `modem-reset`
should escalate automatically from a soft method to a board power cycle. Freeze
package names, machine APIs and migration rules only after all old
CLI/LuCI/button entry points have safe compatibility paths.

## 1.0.0 — stable standalone mobile-connectivity suite

Stabilize the signed first-party suite for modem discovery and provisioning,
connection control, APN policy, selected QMI/MBIM/AT-managed paths, practical
Fibocom FM350 support, eSIM lifecycle and the unified optional LuCI frontend.
The same supported modem state converges safely whether the modem was attached
before installation, after installation or present internally at boot. Every
stable support claim has documented runtime, lifecycle and hardware evidence.
