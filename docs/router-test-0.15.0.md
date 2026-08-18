# 0.15.0 WH3000 AT-dial validation

Date: 2026-08-18
Status: **runtime gate complete for the FM350-GL path.** The packaging gate is
not: everything below ran against files deployed directly onto the router, not
against APKs built by the official SDK. Modem and SIM identifiers are omitted.

Four defects were found here that no fixture had caught, and each is recorded
with what it would have cost. That is the argument for the gate.

## Environment

- OpenWrt 25.12.5 on the Huasifei WH3000 Pro, kernel 6.12.94;
- internal Quectel RM520N-GL in QMI composition, owned by ModemManager, bound to
  the user-created interface `wwan`, in production as the backup WAN;
- Fibocom FM350-GL on the free USB port at `2-1.3`, **two modems present at
  once** throughout;
- primary uplink is WiFi, so an administrative session surviving is never by
  itself evidence;
- installed packages remained 0.14.1. The 0.15.0 runtime files were copied into
  place and removed afterwards; `kmod-usb-net-rndis` was installed from the
  official feed and left in place.

## Confirmed as the contracts predicted

**The modem arrives with no data path at all.** `2-1.3` had no network device and
`rndis_host` was not loaded — only `cdc_ether` and `cdc_ncm` were. The
driver-binding step is load-bearing, not defensive.

**Installing a protocol handler does not register it.** With
`/lib/netifd/proto/apn_atdial.sh` in place, `ubus call network
get_proto_handlers` still did not list `apn_atdial`. It appeared only after the
network was restarted, and persisted afterwards.

**The declared kernel dependency is not optional.** With the handler installed
but `kmod-usb-net-rndis` absent, `modprobe rndis_host` silently did nothing and
the handler reported `NO_NETDEV` without blocking restarts — correct behaviour
for a modem with no data path. Installing the kmod produced `eth2` immediately.
This was self-inflicted, because deploying files skips the package's
dependencies, but it exercised the failure honestly.

**The full path works.** Provisioning an FM350-GL produced: AT identity read
through `apn-autoconfig-modem`, ICCID and home network resolved (PLMN 26202),
`web.vodafone.de` selected from the provider database, context activated,
address assigned by the operator, and `http=200` fetched **through `eth2`**. The
section was promoted with `autoconnect: true`, on a default route with metric
1024 — least preferred, so it could not take the default route from the working
uplink.

**Reconnect is lossless from the user's point of view.** A `reconnect` tore the
context down, re-dialled and returned `http=200`.

**`modem-reset` selects `at` and works.** Owner state was `netifd-direct`
because this project's own protocol held the session; the reset went out over
the AT control port, the modem left the bus, returned, and its identity and
owner were available again.

**ModemManager coexistence held throughout.** Every step above ran while the
RM520N-GL stayed up on `wwan0`, and `mmcli -L` listed only the Quectel for as
long as the inhibition was held. Starting the holder made ModemManager release
the FM350; stopping it made ModemManager reclaim it; deprovisioning released it
and ModemManager took it back. The production modem's ModemManager index never
changed.

## Defect 1: ModemManager ownership chose a protocol it cannot drive

`provision-plan` for the FM350 answered `protocol: modemmanager`, because
ModemManager ownership short-circuited the mapping before anything else was
considered. ModemManager publishes this modem as `model unknown` and has no
control channel for it, so the section would have been one netifd can never
bring up — a failure that looks like success at the moment it is created.

Every other field in the same record already said so: no control device, no data
device, observed protocol `at`.

ModemManager now selects its protocol only when there is a control channel for
it to drive. Fixed with regressions in both directions.

## Defect 2: the registration restart cost administrative access

The restart that registers the protocol took down the WiFi network the
administrator was connected to — which is the router's own AP during a test —
and the session did not come back on its own, because the client associated with
another visible network while the SSID was absent. The router stayed up and kept
serving its own clients; it simply could not be logged into.

The contract had claimed this was safe during provisioning because the user is
"at the console, waiting for it". That is the part that was wrong: being at the
console is not the same as being on a network the restart does not touch.

Provisioning no longer restarts the network implicitly. Registration is a
separate action the administrator takes deliberately, told what it will take
down. A reboot is the other honest answer and is often the better one.

## Defect 3: a reset made the modem permanently unusable

The most serious of the three, and the least visible.

After a successful reset the modem could not be used at all: `at-port` reported
no control port while all seven tty nodes were present. The cache held `dead`
for every one of them, recorded during the reset window — the ports exist
before they answer — and the verdicts survived because a modem returning to the
same socket comes back with an identical topology path and VID:PID. Clearing the
cache by hand restored the modem instantly, which is what confirmed the
diagnosis.

So the operation whose purpose is recovering a wedged modem was the operation
that made it unusable, and nothing in the system reported anything wrong.

0.14.0 had recorded the intent that "a re-enumeration correctly invalidates
everything". The key never delivered it.

A second observation sharpened the fix: after re-enumeration the control channel
moved from USB interface `1.2` to `1.3`. A stale *positive* selection is
therefore as wrong as a stale negative one — it names a port that is no longer
the control channel.

Port verdicts now carry the enumeration counter in their value, so a verdict
from an earlier enumeration reads as absent. The counter is deliberately **not**
in the cache key: that key is shared with the IMEI cache, and scoping identity
by enumeration would drop the modem to a weak tier on every reset and take its
binding to a provisioned section with it. Confirmed on this hardware: after the
fix, a reset left the port resolving immediately, the stamp advanced from 21 to
22, and the identity tier stayed `imei`.

## Defect 4: a provisioned modem only the router could use

The first run left the section in no firewall zone at all. The router reached
the Internet over the modem; nothing behind it could, because forwarding and NAT
never applied, and the IPv6 child reported `zone none`.

This was originally recorded here as a documentation obligation, on the grounds
that provisioning does not mutate firewall configuration. That was the wrong
call and the maintainer rejected it: nobody buys a router to give the router
Internet access, and an administrator who has to configure the firewall by hand
could have configured the connection by hand too — the automation would have
delivered nothing. Firewall zone membership is now in scope, under rules as
narrow as the rest of provisioning.

Verified on this hardware after the change:

- `firewall.@zone[1].network` went from `wan wan6 wwan trm_wwan trm_wwan6` to the
  same list plus `apnmodem1`, and `apn_autoconfig_firewall_zone=wan` was recorded
  on the section;
- `nft` then showed `eth2` in the wan zone's input, forward and output sets and
  covered by `masquerade IPv4 wan traffic` — the rules that were missing;
- the zone was resolved from the interface already carrying a default route, not
  from "the only masquerading zone": this router has **two** masquerading zones,
  `wan` and `wireguard`, so that rule would have been a coin toss.

**What was not demonstrated, and why.** A packet forwarded from a real client
was not captured. The attempt used `ping -I <lan-address>` with the other two
uplinks down, which failed with `Network unreachable` — and that is a property of
the test, not of the configuration: a locally generated packet carrying a foreign
source address does not match the on-link default route, while a forwarded packet
is routed by destination and masqueraded on egress. Traffic out of `eth2` itself
was proven separately (`http=200`).

Closing this needs one client device on the router's WiFi while the other
uplinks are down, and it is the last piece of evidence outstanding for the
firewall change.

## Not covered by this gate

- **roaming refusal**, which needs a roaming registration this SIM cannot be made
  to produce on demand;
- **the Intel XMM path**, because no L850 or L860 exists here. It remains
  `alpha`/`synthetic`;
- **`TERM` during the destructive window on hardware.** It has fixture coverage;
  reproducing it against a live dial needs a deliberately timed kill;
- **the browser pass**;
- **packaging**: SDK build, APK inspection, install/upgrade/removal, and the
  signed-feed smoke.
