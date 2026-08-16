# 0.13.0 frontend test and release plan

Status: planned. Nothing in this document has been implemented or attempted.

0.13.0 reorganizes the optional LuCI package against
[`frontend-contract-v1.md`](frontend-contract-v1.md) and makes one runtime
correction: bearer control stops depending on who created the interface. The
release is finished when the page answers four questions in four places, a
failure is visible from any tab, and a user can start and stop their own
cellular interface from the page that already cycles it.

This is the first release whose subject is legibility, so the gate has an
unusual property: **the fixture suite cannot decide whether it succeeded.** The
0.11.0 and 0.12.0 browser passes each found a defect no fixture could have
caught — a card printing raw JSON with an unmasked identifier, and a card
offering no controls and no reason. The browser pass is therefore a required
gate here, not a formality, and it is performed by the maintainer.

## In scope

- the four areas, the persistent status strip and the tab layout;
- manual APN entry behind a control, in a dialog;
- advanced disclosure for evidence-grade fields;
- click-activated help on non-obvious fields;
- bearer control for any resolvable cellular target, with configuration-changing
  operations still ownership-gated;
- the per-target scoping of `last_result`, because the strip displays it and a
  failure from one target must not describe another. The hardware run recorded
  this as a leftover from the single-target era; the strip is what makes it
  user-visible.

## Explicitly out of scope

- adoption of user-created sections, which stays refused;
- any change to the narrow rpcd surface, the machine APIs or their meanings;
- new backends, new packages, or anything on the AT/Fibocom/eSIM path;
- visual theming beyond what the structure requires.

## Contract tests before implementation

The existing `tests/test-luci-provisioning.js` and
`tests/test-luci-roaming-policy.js` render the real view against fixtures. Every
item below is an executable assertion there unless marked as a browser check.

### Structure

1. each of the four areas renders, and each field appears in exactly one of
   them;
2. the serving network and the matched database provider are labelled
   distinctly and never rendered as two rows with the same name;
3. the status strip renders outside the tabs and contains the target, backend,
   registration, connection state and last result;
4. a failed last result and a running operation both appear in the strip
   regardless of which tab is selected;
5. selecting a tab never removes the strip.

### Manual APN entry

6. the manual form is not present in the page body until its control is
   activated;
7. activating it opens a dialog containing the fields, and cancelling writes
   nothing;
8. the password is passed in the request environment and never as an argument,
   asserted from the recorded wrapper invocation, exactly as today;
9. an invalid APN is refused in the dialog before any wrapper call happens.

### Advanced disclosure and help

10. modem identity, evidence tier, implementation state, validation state and
    device paths are not visible until the advanced disclosure is opened;
11. opening the disclosure reveals them unchanged, with identifiers still
    masked until explicitly revealed;
12. every field carrying help renders a control that opens the text, and the
    text is present in the DOM only after activation;
13. no help is attached to a hover-only handler.

### Bearer control

14. `connect`, `disconnect` and `reconnect` are offered for a user-created
    cellular section bound to an unambiguous modem;
15. `provision`, `deprovision` and profile writes are **not** offered for it;
16. the same three controls are still offered for a project-owned section, and
    removal only there;
17. a modem with `conflicting` ownership, an ambiguous record, or a
    non-cellular section gets no controls at all and an explanation;
18. a disabled project-owned staging section is never startable from the page;
19. every bearer-control verb is confirmed first, and the confirmation names the
    interface it will act on;
20. the runtime accepts bearer control for a non-owned section and still refuses
    every configuration-changing verb for it, asserted in
    `tests/run-tests-modem.sh` rather than through the view.

### Last result scoping

21. a failure recorded for one target does not appear in another target's
    status;
22. an installation upgraded from 0.12.0, whose stored result is not yet
    per-target, reports no result rather than attributing the old one to a
    target.

## Browser gate

Performed by the maintainer, on the reference router, with the page open:

1. the whole page is comprehensible without scrolling, and each area's purpose
   is evident from its heading and first rows;
2. the production modem — bound to a user-created interface — now offers
   connect, disconnect and reconnect, and offers no removal or provisioning;
3. a bearer-control action runs, is confirmed first, and the strip shows it
   running and then its result;
4. manual APN entry opens, cancels cleanly, and does not dominate the page when
   closed;
5. the advanced disclosure hides evidence fields by default and reveals them
   intact;
6. help opens by tap on a touch device, not only by pointer hover;
7. identifiers stay masked until revealed;
8. the browser console is clean.

## Release gate

`sh scripts/verify.sh`, the official OpenWrt SDK build with APK inspection, the
package lifecycle matrix, the browser gate above, then publication and the
signed-feed smoke without `--allow-untrusted`.

A LuCI-only release changes no machine API, which makes it lower risk than the
releases before it and raises a different one: nothing in the automated gate can
tell whether the page became clearer. That judgement is the browser gate's, and
the release does not ship without it.
