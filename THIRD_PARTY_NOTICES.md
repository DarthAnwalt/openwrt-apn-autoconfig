# Third-party notices

## Android Open Source Project APN data

The generated provider database contains selected and modified records derived
from `device/sample/etc/apns-full-conf.xml` in the Android Open Source Project.

Copyright 2006, The Android Open Source Project

The AOSP-derived portion is licensed under the Apache License, Version 2.0. A
copy is in `data/licenses/Apache-2.0.txt`. The project filters Internet-capable
profiles, removes disabled and service-only entries, normalizes fields,
deduplicates records, assigns project-specific priorities, merges other data
and converts the result from XML to TSV. The exact upstream commit is recorded
in `data/provider-sources.json`.

## GNOME mobile-broadband-provider-info

The generated database also contains transformed records from GNOME
mobile-broadband-provider-info `serviceproviders.xml`, whose header identifies
Antti Kaijanmaki, Dan Williams and other contributors. The work carries the
Creative Commons Public Domain Dedication and Certification (`CC-PDDC`); a copy
is in `data/licenses/MBPI-CC-PDDC.txt`. The exact upstream commit is recorded in
`data/provider-sources.json`.

## luci-app-5gmodem (behavioural reference, no code incorporated)

The AT-dial protocol added in 0.15.0 was designed after studying
`luci-app-5gmodem` by Fil Dunsky (GPL-3.0), which drives several of the same
modems in production. **No code from it is incorporated into this repository**,
and this project's packages remain MIT; the acknowledgement is for factual
findings, which is what was actually used.

Those findings are specific and are credited where they are applied:

- that a modem in an RNDIS composition may arrive with no bound driver, so a
  protocol handler must load the usbnet driver itself before any network device
  exists;
- that `AT+CGDCONT` rejects the non-standard `IPV4` on some devices, leaving the
  previous context silently in place;
- that a bare re-activation hangs on a half-active context, while releasing it
  first does not;
- that an active context on a detached modem yields an address that carries no
  traffic, so packet-service attachment must be checked before a context is
  reused;
- that PDP authentication does not survive a modem reboot while the context
  definition does, so a matching context can still be an unauthenticated bearer;
- that the Intel XMM devices need an explicit data-channel binding, a vendor DNS
  query, and ARP disabled on the link, without which the interface is up and
  carries nothing;
- that Fibocom L850 and L860-GL-16 enumerate with the same USB identifiers, so
  the USB id cannot distinguish them;
- that netifd registers protocol handlers only at start-up while executing them
  from disk on every dial, and that restarting the network from a package script
  can take a remote router off the network.

Where this project's safety rules and that project's implementation disagree,
this project's rules were followed: the AT port lock here is mandatory rather
than opportunistic, ambiguous modem identity fails closed rather than being
resolved best-effort, discovery has no side effects, teardown releases the
bearer rather than leaving it outside netifd's ownership, and identifiers are
never logged in clear text. Those differences are recorded in
`docs/atdial-contract-v1.md` so that a reader can tell a deliberate divergence
from an oversight.

## Separate dependencies

OpenWrt, LuCI, ModemManager, curl and other package dependencies are obtained as
separate OpenWrt packages. They are not incorporated into the APK payloads
published by this repository and retain their own license notices.

## Trademarks

Android is a trademark of Google LLC. GNOME is a registered trademark of the
GNOME Foundation. OpenWrt and mobile operator names and marks belong to their
respective owners. Their factual use here does not imply affiliation,
sponsorship or endorsement.
