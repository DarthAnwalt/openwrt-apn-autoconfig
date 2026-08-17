# 0.14.0 WH3000 AT transport and port-resolution validation

Date: 2026-08-16
Status: complete for the runtime gate. Everything below was run against
**installed 0.14.0 packages** built by the official SDK, unless a section says
otherwise.

One qualification on the browser gate, recorded rather than glossed: the first
pass was performed by the maintainer and found two defects — every modem shown
as "Unidentified", and a reset button naming the wrong action. Both were fixed
and the resulting card contents were then verified from the machine API on
hardware rather than by a second pass in the browser. The release was cut on
that basis, at the maintainer's decision.

## Environment

- OpenWrt 25.12.5 r33051-f5dae5ece4 on the Huasifei WH3000 Pro, kernel 6.12.94;
- internal Quectel RM520N-GL in its QMI composition, owned by ModemManager and
  bound to the user-created netifd interface `wwan`;
- a Fibocom FM350-GL attached to the free USB port in a carrier for the duration
  of this work, giving **two modems present at once** — the internal modem could
  not be swapped out, and running both turned out to be the more useful shape;
- the router's primary uplink is WiFi and the modem is the backup path, so an
  administrative session surviving is never by itself evidence;
- the first-contact census and the first resolver trial ran from a scratch
  directory; everything after them ran against installed packages upgraded from
  0.13.2. The reset pin was cleared briefly to exercise one method and restored
  immediately, and is the only configuration this gate wrote;
- modem and SIM identifiers intentionally omitted from this record.

## First contact

Both modems are behind the same internal hub. The FM350 presents **seven tty
nodes and no network device at all**: its RNDIS interface pair has no driver
bound and `rndis_host` is not loaded, which is a fact for 0.15.0 rather than
this release. It exposes **no USB serial**, so it is recorded at the
`weak-vidpid` tier and can only reach a strong tier through an AT-supplied IMEI.

Probing each of its seven ports by hand, with a five-second bound:

| Ports | Behaviour |
|---|---|
| five of seven | accept the write and never answer |
| two | answer, return the same model string, and agree on every later read |

The two responders differ in **echo state at the same moment** — one echoes the
command back, the other does not — which is why echo is treated as a per-port
property and the first exchange has to tolerate its own echo.

Three findings from this census changed the contracts before any code was
written; they are recorded in the commit history and in
[`testing-0.14.0.md`](testing-0.14.0.md). The most consequential is that **the
router has no `timeout` executable**, so the watchdog is not a fallback for
minimal images — it is the only bounded path that has ever run on this hardware,
including for the QMI adapter's AT fallback that was already marked
hardware-validated.

## ModemManager claims both modems, and publishes the second one late

`mmcli -L` immediately after attachment listed only the internal modem. An hour
later it listed both. `logread` shows ModemManager processing the hotplug for
all seven tty nodes at attach time and publishing the modem object only once it
had finished — slow for exactly the reason our own sweep is slow, since most of
those ports never answer.

Two consequences, both now covered by regressions:

1. the resolver correctly **refused** the owned modem with the blocked exit
   class and issued zero probes;
2. ownership is not fixed at attachment, so a port selection cached while a
   modem is unowned must not become a licence once ownership arrives.

ModemManager holds the FM350 as **"model unknown"** — it claimed a device it
cannot drive, while holding the ports that would let something else drive it.

## Resolver trial, with ModemManager stopped

ModemManager was stopped for the trial and restarted afterwards; `wwan` returned
to `up` and no lock or scratch file was left behind.

| Observation | Result |
|---|---|
| Discovery before any request | no probe issued; `at_device` empty on both records |
| Cold resolve on the seven-port modem | correct port selected, **6 s** |
| Second resolve | same port, **1 s** |
| Negative cache | the silent port recorded `dead`, the working one `ok`, keyed by USB interface path |
| Inventory after resolution | `at_device` populated from cache, `at_identity: true` |
| Internal modem, ModemManager stopped | `owner_state: netifd-direct` as observed that day, `at_identity: false`, `reset: true`. That state has since been corrected to `none` — see the last section |
| Scratch files in `/tmp` afterwards | none |

The six seconds are the arithmetic the census predicted: ascending order reaches
one silent port, pays its five-second bound once, and succeeds on the next. A
modem whose only responder sat at the end of the list would have paid that bound
five times, which is why discovery does not sweep and why failures are cached.

## Identity read, same window

`at-identity` against the seven-port modem returned the complete v1 identity
contract in seven seconds, cold, against a live SIM:

| Field | Result |
|---|---|
| `iccid` / `imsi` | read successfully (values omitted from this record) |
| `operator_id` | empty, as specified |
| `serving_operator_id` | numeric PLMN, matching the manual census |
| `registration_state` / `roaming` | `home` / `false`, from `AT+CEREG?` |
| `access_technologies` | `lte,5gnr` — `<AcT>` 13 is E-UTRA-NR dual connectivity |
| `modem_state` | `enabled` |
| `signal_quality` | derived from `AT+CESQ` RSRP |
| `manufacturer` / `model` / `firmware_revision` | all three present in the inventory record afterwards, with no further probe |

Every value matches the manual census except the signal percentage, which had
moved by five points between the two readings — a live radio, which is the point
of reading it rather than caching it.

The operator this SIM belongs to has 23 rows in the shipped provider database,
so the identity-to-matching path has a real target on this hardware. Wiring the
match itself is a later step.

ModemManager was restarted afterwards. It rediscovered the internal modem and
`wwan` returned to `up`; note that ModemManager needs a minute or so after a
restart before it publishes anything, so an immediate check reports no modems
and a down interface without anything being wrong.

## Observation deferred rather than fixed, then fixed

With ModemManager stopped, the internal modem reported `owner_state:
netifd-direct` although its netifd section is `proto=modemmanager`. Nothing
unsafe followed — with ModemManager down the ports genuinely are free, and every
operation re-reads ownership under its locks — but the label was loose, and it
had come to carry a consequence it did not have before, since `netifd-direct`
permits AT access. This is pre-existing classification behaviour rather than
something this release introduced, and it was recorded here rather than changed
in the middle of the AT work.

It has since been corrected: a section whose proto delegates the session to
ModemManager is not evidence of a netifd-held session, so with no ModemManager
object the state is now `none`. The record still reports `netifd_interface:
wwan`, and resolution, provisioning refusal and reset are unchanged — see
[A binding is not a session](modem-contract-v1.md#a-binding-is-not-a-session).
The permission to open an AT port is the same under `none` as it was under
`netifd-direct`, so this observation is a naming correction and not a change to
what the release may do; the fixture regression reproduces the router's exact
record and fails against the old classification.

## Reset methods, all three exercised

Installed packages, both modems attached. The two in-band methods were timed
after the departure rule was added; see the defects below for why that rule
exists.

| Method | Modem | Result |
|---|---|---|
| `gpio` | internal, pinned | 51 s. Stopped and restarted **its own** interface, left the second modem untouched, and correctly skipped the departure wait — board power has already removed the device. Released behaviour unchanged. |
| `at` | USB-attached, unowned | 70 s. Departure observed, then return with the same `imei:` identity and a re-resolved control port. |
| `modemmanager` | internal, reset pin temporarily cleared so the method would be selected | 52 s. Departure and return both observed. The pin was restored afterwards and the interface came back up. |

The `modemmanager` method also has its refusal path from hardware: asked to
reset the USB modem, which ModemManager holds as "model unknown", it answered
`Unsupported: Operation not supported`. The runtime reported a retryable failure
and did **not** reach around the owner to reset it another way, which is the
behaviour the single-owner rule requires.

## Defects this gate found, none of which fixtures could have

### A neighbouring modem satisfied another modem's reset wait

The first soft reset reported success in three seconds and named the *other*
modem in its completion message. `wait_for_control_owner` passed its target to
awk as `$modem_id` — the same name `scan_inventory` reassigns per record — so
the comparison ran against whichever record was scanned last, and any idle modem
matched at once.

Latent since 0.10.0 and therefore present in released versions: with one modem
the clobbered value equals the target. Auditing the whole function against the
scan's variable names then turned up two more, the worst being the bound
interface used for `ifup` — on a two-modem router a reset could have restarted
somebody else's interface.

### An in-band reset was counted as done before the modem moved

With the naming fixed, the reset still reported success in three seconds.
`AT+CFUN=1,1` returns while the modem is still fully enumerated, so waiting for
"present with the expected owner" was satisfied by a modem that had not started
resetting. Board power does not have this problem, having removed the device
synchronously.

The departure is now observed first, and never seeing one is a failure.

### The departure bound was three times too small

The first bound was 20 seconds, chosen because it sounded generous. Timing the
cycle by hand: **the device leaves the bus 36 seconds after the command and
returns 32 seconds later.** The runtime had been refusing three consecutive
resets that in fact worked. Departing is slower than returning on this device,
which is the opposite of what the sequence suggests — hence the measurement
rather than an estimate. The default is now 90 seconds.

## Package lifecycle with both modems attached

| Step | Result |
|---|---|
| Upgrade 0.13.2 → 0.14.0 | clean. The config conffile is kept and the new options land in `.apk-new`, so the compiled defaults apply — which is the real upgrade path and the one every test above ran on |
| Removal | state directory gone including the new AT port cache, quirk table and config removed, **no lock erased** (none were live), the core package still answers, and `wwan` stayed up throughout |
| Reinstall | both modems rediscovered and unambiguous; the USB modem correctly returns to `weak-vidpid`, since its cached IMEI went with the cache |

The AT port cache needed a postrm fix found while preparing the release: it was
not in the removal list, so the package's run directory could never be emptied
and cached resolutions outlived the package.

## Unrelated observation, not part of this release

`/tmp` holds scratch files from the **core** package across four PIDs and
several hours — the same class of leak 0.13.2 fixed in the modem package, which
itself now leaves nothing. The core's paths are assigned at start-up and its
exit trap removes them, so the likely cause is processes being killed rather
than exiting. Tracked separately; it predates this release and is not a
regression from it.
