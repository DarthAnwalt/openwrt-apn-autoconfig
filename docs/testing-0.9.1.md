# 0.9.1 test strategy

The 0.9.1 development line uses an evidence ladder. No synthetic result is
described as proof that a physical modem works.

## Automated gate available without modem hardware

Every change must pass:

- POSIX-shell syntax checks and repository `verify.sh`;
- the complete ModemManager regression suite from 0.9.0;
- `targets-json` v2 capability/evidence assertions;
- QMI home and roaming identity fixtures;
- separation of SIM home identity from the serving PLMN;
- provider matching from IMSI when QMI cannot report a reliable home PLMN;
- missing adapter, failed command, malformed ICCID and unsafe-device failures;
- single and ambiguous official-style QMI `devpath` resolution;
- an allow-list assertion that QMI identity issues no mutating `uqmi` command;
- a same-physical-USB AT fallback fixture using only fixed read-only commands;
- rejection of unrelated serial ports, sysfs escapes and malformed AT output;
- QMI authentication/IP-family mapping, successful apply, idempotent reconcile,
  dual-stack-to-IPv4 fallback, automatic failure rollback and explicit reset;
- full-file baseline validation before any UCI mutation and rejection of
  cross-backend option names;
- QMI execution of the optional board reset flow after modem power returns;
- the existing ambiguity, state migration, rollback, locking, URL, UCI and
  command-injection tests.

Fixtures in `tests/fixtures/qmi/` follow the JSON keys produced by upstream
`uqmi`. They contain synthetic identifiers reserved for tests and are not
claimed to be captures from the reference modem. A later sanitized capture can
be added as a new fixture only after its identifiers and operator-specific
secrets have been replaced consistently.

## OpenWrt integration gate

Before an alpha package is offered for router testing, it must also:

- build with the official OpenWrt 25.12 SDK;
- install with and without `modemmanager` and `uqmi` present, while always
  declaring and installing the small common `sms-tool` dependency;
- expose unavailable backends without selecting them as writable targets;
- preserve upgrade and removal behavior for an existing 0.9.0 baseline;
- contain no undeclared executable or library dependency;
- keep the WH3000 hotplug handler and `kmod-button-hotplug` dependency outside
  the GUI-independent core package, and reject reset without its marker.

Removing the hard package dependency on a modem manager is intentional. The
manager required by a configured target (`modemmanager`, later `uqmi` or
`umbim`) is installed by that OpenWrt configuration, while the core remains
usable by another GUI or integration without pulling an unrelated manager.

## Remaining hardware gate for stable QMI write/apply

The following work is blocked on the isolated router and must not be simulated
away:

- retain the observed RM520N behavior: serving-system and UIM state succeed,
  native QMI ICCID/IMSI return `Not supported`, and read-only AT identity works;
- verify SIM/PIN/not-present and registration transitions;
- confirm the implemented QMI profile/authentication/IP-family UCI mappings;
- test packaged netifd ownership, dynamic IPv4/IPv6 interfaces and reconnect timing;
- force bearer rejection, timeout, hot-unplug and power interruption;
- prove exact profile rollback, repeated reboot and removal recovery;
- repeat the complete ModemManager live regression after the QMI changes.

The alpha can expose its implemented runtime capability while remaining
`implementation_state: alpha`. It must not become stable 0.9.1 until the
remaining packaged hardware gate passes.

## RM520N read-only observation (2026-07-19)

The reference Huasifei/RM520N exposed `/dev/cdc-wdm0` through `qmi_wwan` and
four sibling `ttyUSB` ports. With ModemManager temporarily stopped, native
`uqmi --get-iccid` and `--get-imsi` returned `Not supported`, while
`--get-serving-system` and `--uim-get-sim-state` succeeded. The packaged
OpenWrt `sms-tool` returned valid ICCID and IMSI responses for the fixed
`AT+QCCID` and `AT+CIMI` queries on a sibling AT port.

The new adapter file was then exercised directly from `/tmp`. It resolved the
serial port from canonical sysfs paths, returned the expected identity contract
and home registration, and did not alter the QMI profile, UCI configuration or
AutoAPN persistent state. ModemManager and the existing `wwan` bearer returned
successfully afterward. This validated the direct read-only helper path on one
modem but did not yet change the public evidence fields or imply QMI
profile-apply support.

The CI-built and installed `r3` package subsequently passed `targets-json`,
`detect-json` and `status-json` through that same live QMI/AT path. The identity
lengths and home registration were correct, `reconcile` stopped at the expected
unsupported profile-apply gate (exit 4), and the modem profile, UCI files and
AutoAPN state were unchanged.

At that earlier read-only milestone the evidence flag remained conservative
(`synthetic`/false), because it is target-wide rather than capability-specific.
The later write/apply implementation supersedes that interim state and requires
the additional gates above.

A separate short netifd bearer test exposed an IP-family distinction. With the
existing `ipv4v6` setting, Vodafone accepted IPv4 but rejected the IPv6 QMI
session. ModemManager normally retains the working IPv4 bearer, whereas the
OpenWrt 25.12 `qmi.sh` treated the IPv6 failure as fatal, tore down IPv4 and
entered a reconnect loop. With `pdptype=ipv4`, the same official QMI protocol
handler came up, exposed an L3 device with one IPv4 address and returned HTTP
204 through the selected mwan3 path. The test then returned to ModemManager;
after allowing asynchronous netifd teardown to release the control channel,
profile 1 matched the saved JSON baseline byte-for-byte and UCI was clean.

This proves a working IPv4 QMI bearer on the reference modem, not long-term
stability. The engine now implements the observed dual-stack fallback and
profile rollback synthetically; packaged failure, hot-unplug, reboot and soak
tests remain required before the backend becomes stable or replaces
ModemManager on the production router.

## RM520N packaged write/apply gate (2026-07-22)

Official OpenWrt 25.12.5 SDK artifacts were installed on the reference
Huasifei/RM520N after verifying their CI `SHA256SUMS`. The production
ModemManager configuration and persistent AutoAPN state were copied to the
router's recovery partition first; QMI used a separate `qmitest` UCI section
and a temporary state/cache directory.

The packaged QMI backend passed:

- target discovery and read-only SIM/operator detection through the native
  QMI plus same-device AT identity path;
- successful APN apply, real HTTP connectivity through the selected QMI L3
  device, and idempotent reconcile without an interface restart;
- reset to the exact target-scoped UCI baseline;
- a forced all-candidates failure followed by automatic rollback: the UCI
  section SHA-256 and physical profile JSON matched their pre-test snapshots;
- a live `ipv4v6` rejection followed by exactly one IPv4 retry, successful
  connectivity, canonical `pdptype=ip`, and cached effective family `ipv4`;
- backend policy isolation: a staged `allow_roaming=0` was ignored, status
  reported `roaming_policy: unsupported`, and the policy command remained
  unavailable without mutation;
- guarded Huasifei GPIO modem power-cycle, QMI device/SIM return, netifd
  recovery, APN reconciliation and real connectivity.

The first browser observation still targeted the preserved production
`network:wwan` ModemManager section while the isolated bearer was deliberately
named `network:qmitest`; therefore LuCI correctly reported the configured
target as unavailable even though explicit QMI CLI queries succeeded. Future
isolated GUI gates must temporarily select `qmitest` under Settings → Mobile
target, verify operator/APN/status and target-scoped actions, then restore the
saved configuration. LuCI now names discovered alternatives in this error
state instead of leaving a generic unavailable message.

Hardware testing found two restart races that the synthetic suite had not
exposed. A two-second QMI teardown delay allowed netifd to query the SIM before
old client IDs were fully released; the RM520N then entered qmi.sh's illegal
SIM recovery path. A six-second bounded quiet period removed the timeout and
unnecessary SIM power-cycle across apply, reset and rollback. Cold GPIO reset
also originally performed a direct identity query immediately before handing
the device to qmi.sh. Recovery now follows identity readiness, bounded settle,
netifd interface readiness, and only then APN reconciliation. The corrected
`r6` modem-reset completed with exit 0, GPIO power-on, home registration,
successful HTTP, and no QMI request timeout or internal SIM power-cycle.

At the end of the gate, the temporary engine state was reset, `qmitest` was
stopped, QMI profile 1 matched the pre-experiment JSON byte-for-byte, and the
saved `network` and `apn-autoconfig` files matched their snapshots by SHA-256.
ModemManager then returned to home registration and `web.vodafone.de`; its
reconcile was idempotent and UCI was clean.

This is strong single-device hardware evidence, but the public QMI evidence
flag remains conservative until the remaining stable gates cover reboot,
hot-unplug/replug, package removal/reset-all and a bounded soak. Physical
button event dispatch should also be repeated with QMI active even though the
same guarded reset command and the release-only hotplug mapping have each been
tested independently.

## QMI LuCI concurrency finding (2026-07-22)

The pre-reboot LuCI gate exposed a hardware-only serial contention path. On the
minimal OpenWrt image, no external `timeout` command was installed and a
QMI-to-AT identity fallback could leave `sms_tool` blocked, causing LuCI's RPC
request to time out. The first bounded fix prevented indefinite processes, but
simultaneous boot reconciliation and LuCI status still contended for the same
AT port and made a cold scan exceed the RPC window.

The corrected adapter combines an internal TERM/KILL watchdog, a bounded
per-control-device identity lock, a root-owned volatile cache of the validated
sibling AT port, sysfs revalidation before reuse, and suppression of a
redundant vendor ICCID attempt after the standard command itself times out.
Signal-info collection is also bounded and optional: malformed telemetry does
not invalidate otherwise complete SIM identity.

Synthetic tests force a hanging `sms_tool`, two concurrent identity callers,
an unrelated USB serial port and a timed-out earlier sibling port. The final
packaged hardware gate must repeat cold boot reconciliation and LuCI loading
with the volatile port cache absent, then prove normal repeated status polling.

The production Huasifei regression is deliberately narrower. It must follow
[`router-test-0.9.1-alpha.md`](router-test-0.9.1-alpha.md), keep the existing
ModemManager configuration and prove rollback to the locally staged 0.9.0 APKs
before installing the alpha.
