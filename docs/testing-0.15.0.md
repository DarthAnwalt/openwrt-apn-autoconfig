# 0.15.0 AT-dial test and release plan

Status: implementation and fixture coverage complete; **no hardware, SDK or
publication gate has run.**

What has passed, as of 2026-08-18:

- `sh scripts/verify.sh`, including both LuCI suites — Node.js is installed on
  the maintainer's machine, so they run rather than being skipped;
- every fixture assertion listed below, in `tests/run-tests-atdial.sh`,
  `tests/run-tests-modem.sh`, `tests/run-tests.sh`,
  `tests/test-package-lifecycle.sh` and the two LuCI suites.

What has **not** run, and must before this release is called anything:

- the official OpenWrt 25.12 SDK build and the inspection of the produced APK.
  The SDK is a Linux x86_64 toolchain and the work was done on macOS, so this
  goes through the GitHub Actions workflow;
- every step of the hardware gate below;
- the signed-feed smoke.

Nothing in this document may be read as evidence for those. In particular the
`stable`/`hardware` capability the AT-dial backend reports is a claim about the
FM350-GL path that **the hardware gate has not yet confirmed in this release**;
it rests on the contract being implemented as written, which is exactly the kind
of assumption this project's evidence ladder exists to refuse.

0.15.0 adds the first netifd protocol this project ships, `apn_atdial`, against
[`atdial-contract-v1.md`](atdial-contract-v1.md). The release is finished when a
modem with no control channel is provisioned, dialed, verified against the real
Internet, interrupted and recovered, all while the ModemManager-owned modem
beside it keeps working — and when everything this release claims about an Intel
XMM device is visibly marked as unproven, because it is.

The unusual thing about this plan is that it carries **two evidence levels on
purpose**. The Fibocom FM350-GL is on the bench and its path is validated. The
Intel XMM tail for the L850/L860 is written from another project's hardware
reports and has never run here. Merging those into one claim would be the
single most misleading thing this release could do, so the plan keeps them
apart at every stage, down to the capability fields the runtime reports.

The prior release's lesson applies unchanged: a fixture AT port answers
instantly and correctly by construction, which is the case that never breaks.
What fixtures cannot reproduce here is a driver that never binds, a link that is
up and carries nothing, a context that reports itself active while the modem is
detached, and a network restart that takes away the interface the tester is
using.

## In scope

- the `apn-autoconfig-proto-atdial` package and the `apn_atdial` handler;
- driver binding (`rndis_host`, `cdc_ether`, `cdc_ncm`) and bounded netdev
  resolution, including the numerically-lowest-interface rule;
- AT port resolution delegated to `apn-autoconfig-modem`, and the mandatory
  shared port lock held for the whole dial;
- registration classification, including `stat` 6, 7, 9 and 10, and the
  `+COPS` mode-2 re-enable;
- cold dial, context reuse guards, PDP-type fallback and `AT+CGAUTH`;
- static IPv4 publication and the dynamic `dhcpv6` child;
- teardown that releases the context and notifies nothing;
- the transport quirk table, its keys `data_channel`, `dns_source` and
  `link_arp`, and the XMM tail they drive;
- provisioning of an `at` modem to `proto=apn_atdial`, including the netifd
  registration gate and the `netifd_restart_required` field;
- the `mmcli --inhibit-device` holder, its lifecycle and its rollback;
- the `atdial` APN backend, and engine identity delegated to the modem package;
- LuCI page-load cost and per-modem presentation;
- the shipped `stat` 9/10 identity defect found while writing these contracts.

## Explicitly out of scope

- **USB composition switching.** An L850 or L860 may need `AT+GTUSBMODE` and a
  modem reboot to reach the NCM composition at all. It is destructive,
  vendor-specific, and cannot be verified without the device;
- any AT profile write; profile fields remain UCI options applied by netifd;
- free-form AT from any public control, UCI, the environment or the GUI;
- band selection, SIM slot switching, SMS, USSD, firmware or radio-mode control;
- eSIM, which is 0.16.0, including the SIM-slot level the LuCI work prepares;
- per-target lock granularity and automatic reset escalation, both still
  deferred to 0.17.0 and recorded in [`architecture.md`](architecture.md);
- adoption of user-created `apn_atdial` sections, which remains out of scope for
  provisioning generally.

One out-of-scope item from 0.14.0 has moved in: ModemManager inhibition was
recorded there as an eSIM-transport problem for 0.16.0. It arrives here for a
different reason — a modem cannot be dialed over AT by this project while
ModemManager owns it — and the eSIM transport question is unaffected.

## Fixture assertions before implementation

### Netdev resolution and driver binding

1. no network device and no loaded usbnet driver → the drivers are loaded and
   the device is found within the bound;
2. no network device and the drivers already loaded → `modprobe` is still a
   no-op and the bounded wait still applies;
3. nothing appears within the bound → `NO_NETDEV`, restart **not** blocked;
4. a `device` from UCI that does not exist in `/sys/class/net` →
   `NETDEV_MISSING`, restart blocked;
5. three interfaces on one device numbered `1.6`, `1.8`, `1.10` → the one at
   `1.6` is selected. A lexical comparison picks `1.10` and this assertion is
   the only thing that catches it;
6. a `usbpath` that no longer exists while `modem_id` resolves → the binding is
   re-resolved rather than failing or guessing.

### Port, lock and ownership

7. the modem package refuses for ModemManager ownership → `OWNER_CONFLICT`,
   restart blocked, and **zero AT commands are issued**;
8. no port resolvable → `NO_AT_PORT`;
9. the port lock is held by another process for longer than the bound →
   `AT_PORT_BUSY` and no dial. Proceeding unlocked must be unreachable, and the
   assertion is on commands issued, not on the exit code alone;
10. the lock is released before addresses and the IPv6 child are published, not
    after — asserted by observing lock state at publication time;
11. ownership changes between resolution and the lock being held → the dial
    aborts. This is the sequence the reference router produces by itself.

### Registration

12. `stat` 1, 6 and 9 → dial proceeds as home;
13. `stat` 5, 7 and 10 with `allow_roaming=0` → `ROAMING_NOT_ALLOWED`, restart
    blocked; with `allow_roaming=1` → dial proceeds;
14. `stat` 3 → `REGISTRATION_DENIED`, restart blocked;
15. no registration within the bound → `NOT_REGISTERED`, restart **not**
    blocked;
16. `+COPS: 2` → `AT+COPS=0` is sent exactly once per attempt; `+COPS: 1` → it
    is never sent;
17. `at_read_registration` maps 9 and 10 rather than falling through — the
    regression for the shipped defect, asserted on all three sources.

### Dial

18. `pdptype` `IPV4`, `ipv4`, and an unknown value → `IP`, `IP`, `IPV4V6`;
19. `AT+CGACT=0,1` precedes the first activation unconditionally;
20. `auth=none` → `AT+CGAUTH=1,0`; `pap`/`chap` → the matching protocol;
    `pap-or-chap` → bounded CHAP then PAP, with the effective value cached;
21. no credential or SIM identifier appears in any log line, asserted by
    scanning captured output rather than by reading the source;
22. no address under the configured PDP type → exactly one retry under the
    complementary type, and no retry at all when the first attempt succeeded;
23. still no address → `NO_IP_ADDRESS`, restart blocked.

### Context reuse

24. live context, matching APN and PDP type, `CGATT=1`, no re-enumeration →
    reused;
25. APN differs → cold dial. This is the "old APN from the previous SIM lives
    forever" case;
26. PDP type differs → cold dial. This is the "IPv6 never appears" case;
27. `CGATT=0` → cold dial. This is the "address exists, traffic does not" case;
28. auth configured and `devnum` changed since `AT+CGAUTH` was sent → cold dial.
    This is the same failure reached by a different route.

### Publication and teardown

29. empty `CGCONTRDP` gateway → on-link default route; a present one → a
    gateway route;
30. live context v6-capable → the `dhcpv6` child is created and inherits the
    parent's firewall zone; IPv4-only after a fallback → no child;
31. teardown deactivates the context and sends no `proto_send_update`.

### Quirks and the XMM tail

32. no quirk entry → none of the three XMM behaviours occur. An untested modem
    gets nothing, which is the table's whole rule;
33. `data_channel=xmm` → the channel binding and `AT+CGDATA` are sent, and only
    after an address exists;
34. `dns_source=xdns` → `AT+XDNS=1,1` precedes activation and DNS is read from
    `AT+XDNS?` rather than `CGCONTRDP`;
35. `link_arp=off` → ARP is disabled and the route is on-link with no gateway;
36. an Intel vendor id with a product the table does not list gets nothing —
    the assertion that a vendor id alone is not a licence, since the two
    reported Intel products are what the evidence covers.

### Interruption

37. a real `TERM` during the destructive window → the context is released, the
    link is left as it was found, and every lock is released in reverse order.
    Asserted under an interpreter where an untrapped signal is fatal, per the
    existing rule in `run-tests.sh`.

### Provisioning, ownership and lifecycle

38. protocol installed but not registered → `provision-plan` reports
    `netifd_restart_required: true` and `provision` restarts, re-checks, and
    proceeds;
39. still unregistered after the restart → fail closed, **no section created**;
40. the restart happens before the section transaction is armed, asserted by
    ordering rather than by outcome;
41. no package script restarts the network, asserted against the built package's
    scripts rather than the source tree;
42. provisioning starts the inhibit holder, ownership moves, and deprovisioning
    stops it and restores the prior state exactly;
43. ModemManager claims the modem anyway → detected and recovered, not assumed
    away;
44. the holder dies → the modem returns to ModemManager rather than to nobody;
45. a holder running for a modem this project did not provision → reported, not
    adopted;
46. two simultaneous provisions → exactly one is accepted;
47. install, offline `IPKG_INSTROOT` install, 0.14.1 upgrade and removal, each
    with the modem already attached.

## Hardware gate

Two modems attached at once throughout, as in 0.14.0: the internal RM520N-GL
owned by ModemManager and in production, and the FM350-GL in the free port.
**The RM520N-GL keeping its connection is an assertion, not a courtesy** — it is
the whole reason the inhibit approach was chosen over restarting ModemManager.

1. **Inhibit.** Provision the FM350; confirm ModemManager releases it, that the
   RM520N session is untouched throughout, and that the inhibitor is a live
   supervised process rather than a side effect. Kill the holder and confirm the
   modem returns to ModemManager.
2. **Registration gate.** Provision with the protocol unregistered and confirm
   the restart happens, is announced beforehand, and is followed by a
   successful dial. Confirm a package upgrade afterwards needs no restart.
3. **Driver binding.** Confirm the handler loads `rndis_host` and that a netdev
   appears where there was none. This is the step with no fixture equivalent.
4. **Dial and verify.** Full path: provisioning → APN reconcile against the live
   Vodafone Germany SIM → connection → verified Internet access → promotion.
5. **Roaming refusal.** Confirm a roaming registration with `allow_roaming=0`
   refuses and blocks restart, and that enabling the option recovers without a
   reboot.
6. **Interruption.** `TERM` mid-dial; confirm the context, link and locks are
   restored and that the neighbouring modem is unaffected.
7. **Reset.** `modem-reset` on the FM350 under `apn_atdial` ownership, through
   the `at` method, followed by re-enumeration, rebinding and reconnection.
8. **Contention.** An APN operation on the FM350 while the RM520N is busy, and
   the reverse. The global lock still serializes them; that remains the
   deferred 0.17.0 decision and should be observed, not fixed here.
9. **Browser pass.** Page load time measured before and after the LuCI work, on
   the same router with both modems present, and per-modem presentation checked
   with two modems rather than one.

## The XMM path has no hardware gate, and says so

No L850 or L860 is available. The XMM tail therefore completes fixture coverage
only and is released as `implementation_state: alpha`,
`validation_state: synthetic`, `hardware_validated: false`.

Nothing in the release notes, README or LuCI may describe it as supported
without that qualification. It is promoted by driving a real device — obtaining
one is cheap and is the obvious follow-up — and not by a fixture passing, since
the failures that matter here are precisely the ones a fixture asserts away: a
channel binding that was never sent, DNS that arrives empty, and a link that is
up and drops every packet in neighbour resolution.

## Release gate

1. `sh scripts/verify.sh`, with Node.js present so the LuCI suites actually run.
2. Official OpenWrt 25.12 SDK build, and inspection of the **produced APK**
   rather than the source tree — the requirement that exists to catch a file
   that reached a package without being declared, and this release adds a
   package.
3. The package lifecycle matrix above, on hardware that is already attached.
4. The hardware gate, recorded in `router-test-0.15.0.md` with identifiers
   redacted.
5. Signed-feed smoke, including the `apk add` by bare name that clears the
   version constraints the gate's own local installs write. Deferred from 0.14.0
   and 0.14.1; it does not get deferred a third time.
