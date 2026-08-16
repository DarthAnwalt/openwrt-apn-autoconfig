# Frontend contract v1 (0.13.0)

Status: accepted design for 0.13.0. Nothing here is implemented yet. This
document is normative for `luci-app-apn-autoconfig` and for the one runtime rule
the reorganization depends on. It inherits every rule in
[`architecture.md`](architecture.md),
[`provisioning-contract-v1.md`](provisioning-contract-v1.md) and
[`modem-contract-v1.md`](modem-contract-v1.md).

The page grew feature by feature across six releases and now reads as a list of
things that happened rather than a description of a system. The complaint that
started this release is precise: a person cannot tell what separates "Modem
setup" from "Modem inventory", the two are far enough apart that they never
appear together, and nothing on the page can be taken in at a glance. The fix is
not decoration. It is deciding which question each area answers, and letting the
layout follow the answer.

**No existing machine API field changes shape or meaning in this release**, and
no wrapper gains a verb. The narrow rpcd surface, the capability-driven
rendering rule and the identifier-masking rules are unchanged.

One addition is required rather than optional. The capability-driven rule says a
control is never rendered for something that cannot work, and the bearer-control
change below makes "can this interface be started?" a question the frontend
cannot answer from what it already receives. `provision-plan` therefore gains
three read-only fields — `can_control_bearer`, `connection_section` and
`connection_owned` — produced by the same resolver the action uses. Deriving the
answer in JavaScript instead would put a second copy of the safety rule in the
frontend, where it would drift.

## The four areas, and the question each answers

| Area | The question it answers | Backed by |
|---|---|---|
| Modem | What is the hardware doing? | `apn-autoconfig-modem` inventory, connection state, reset |
| APN | Which profile did we choose, and is it still right? | `apn-autoconfig` engine, provider database |
| SIM | Whose subscription is this? | engine identity today, eSIM lifecycle later |
| Settings | How should the program behave on its own? | package configuration |

The overlap that made the old page feel arbitrary is real but not accidental:
the operator name appears under Modem and under APN. They are different facts.
Under Modem it is the **serving network** — who is carrying the radio link right
now. Under APN it is the **matched database provider** — the record the profile
was selected from. In roaming they differ, and that is exactly when a user needs
both. Labels must therefore name the question, not the value: "Serving network"
and "Matched provider", never two rows both called "Operator".

SIM is thin today — identity and little else. It is created now anyway, because
eSIM lifecycle lands in 0.16.0 and an area that appears late reorganizes the
page a second time.

## Status strip

Tabs hide state, and the state most worth seeing is exactly the state a user is
least likely to be looking at when it breaks. A strip above the tabs is
therefore always visible and always shows:

- the selected target and its backend;
- registration and connection state;
- the result of the last engine operation, including failures;
- any operation currently running, with its verb.

A failure never lives only inside a tab. When the last result is a failure or an
operation is running, the strip says so regardless of which tab is open.

## Manual APN entry

Manual entry is the fallback for a SIM the database does not cover. Presenting
it as a permanently expanded form asks every user to fill in something almost
nobody should need, and it dominates a page whose normal answer is "the
automatic path already worked".

It moves behind a control that opens a dialog. The dialog keeps every existing
safety property without exception: the profile is validated before anything is
written, it becomes one candidate through the same baseline, verification and
rollback path as a database profile, and the password travels in the request
environment and reaches the engine only on standard input — never in argv, which
any local process can read.

## Advanced disclosure and help

Two independent rules, both about the same problem: the page states facts
without saying what they are for.

Fields that exist for debugging and for release evidence — the full modem
identity, the discovery evidence tier, implementation maturity, validation
state, USB paths — are collapsed under an explicit advanced disclosure, closed
by default. They stay truthful and stay available; they simply stop being the
first thing a person reads. That the same fields were just corrected in 0.12.0
is not an argument against hiding them: truthful maintainer metadata is still
noise in a daily view.

Non-obvious fields carry a short help text opened by a question control next to
the label. It opens on activation, not on hover: a hover tooltip is unreachable
on a touch screen, and touch screens are how many people administer a router.
Help text explains what the field means and what a user can do about it, in one
or two sentences.

## Connection control no longer depends on who created the interface

This is the one runtime rule the reorganization changes, and it is a correction
rather than a relaxation.

Operations are split by what they actually do:

| Class | Operations | Requirement |
|---|---|---|
| Configuration-changing | `provision`, `deprovision`, profile writes, roaming policy | the section carries this project's ownership markers |
| Bearer control | `connect`, `disconnect`, `reconnect` | one unambiguous cellular target, resolved and confirmed |

Bearer control is `ifup` and `ifdown`. It changes no configuration, and netifd
owns the bearer either way. The APN engine **already** performs both on
user-created interfaces during every reconcile — including the interface whose
Connect button this project used to refuse. Refusing the control while
performing the action was inconsistent, and the explanation for the refusal read
as the project's convenience at the user's expense.

The safety rules that do apply are unchanged and still enforced: exactly one
unambiguous modem and target, no action while ownership is `conflicting`, no
action on a section whose protocol is not cellular, no action while another
operation holds the locks, and an explicit confirmation naming the interface
before anything runs. A disabled project-owned staging section is still never
started outside provisioning, because a staged section has no profile yet and
starting it is exactly the APN-less dial the staging rules exist to prevent.

Adoption is still not part of this. Taking over a user-created section — owning
its profile fields, being able to remove it — remains the separate, recorded
decision [`provisioning-contract-v1.md`](provisioning-contract-v1.md) describes.
Offering to start and stop an interface is not a claim to own it, and the UI must
not imply otherwise.

## What this release does not change

- the narrow rpcd surface: two read wrappers, two mutating wrappers, fixed verbs;
- the rule that a control is never rendered for something that cannot work, and
  that anything refused is explained;
- identifier masking, and the reveal-on-request behavior;
- confirmation before every state-changing verb;
- polling behavior for running operations, including the rule that a lost launch
  answer keeps polling rather than inventing a result.
