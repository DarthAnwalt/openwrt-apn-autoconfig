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

## Separate dependencies

OpenWrt, LuCI, ModemManager, curl and other package dependencies are obtained as
separate OpenWrt packages. They are not incorporated into the APK payloads
published by this repository and retain their own license notices.

## Trademarks

Android is a trademark of Google LLC. GNOME is a registered trademark of the
GNOME Foundation. OpenWrt and mobile operator names and marks belong to their
respective owners. Their factual use here does not imply affiliation,
sponsorship or endorsement.
