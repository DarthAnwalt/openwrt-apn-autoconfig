# Provider database v2

The packaged provider database is a generated, compact runtime artifact. The
large upstream XML files are deliberately not installed on the router.

## Sources

- GNOME `mobile-broadband-provider-info` (MBPI) is the preferred source. Its
  database is dedicated to the public domain and is actively maintained.
- AOSP `device/sample/etc/apns-full-conf.xml` supplements MBPI with additional
  MCC/MNC coverage and MVNO selectors. It is licensed under Apache-2.0.
- `data/providers-overrides.tsv` contains manually verified corrections and
  receives the highest priority.

Exact upstream revisions are pinned in `data/provider-sources.json`. Normal
OpenWrt package builds and router runtime therefore never fetch network data.

## Runtime format

The file is UTF-8, TAB-separated and sorted deterministically. Each data row
contains 12 fields:

```text
mccmnc  imsi_pattern  iccid_pattern  gid1  spn  provider  apn  priority  username  password  auth  ip_type
```

`-` means that a field is not constrained or not supplied. `x` in an IMSI or
ICCID pattern matches one decimal digit. Plain shorter patterns match the
beginning of the corresponding SIM identifier.

The first eight fields extend the v1 matcher without changing its basic data
flow. The final four fields complete the ModemManager profile. v0.6 applies,
caches, reconciles and rolls back all of them together.

Only profiles usable for ordinary Internet access are imported. MMS-only,
IMS, FOTA, XCAP, CBS, emergency and WAP-only profiles are excluded. Disabled
AOSP entries and test-network MCC 001 are excluded as well.

## Regeneration

Check out the two pinned upstream revisions and run:

```sh
python3 scripts/generate-providers.py \
  --mbpi /path/to/mobile-broadband-provider-info/serviceproviders.xml \
  --aosp /path/to/device-sample/etc/apns-full-conf.xml \
  --report data/providers-report.json
```

Alternatively, `sh scripts/update-providers.sh` fetches exactly the revisions
from the manifest, regenerates the runtime database and writes the deterministic
quality report. It is never run during package builds.

The `Update provider database` GitHub Actions workflow runs every Monday. It
resolves the latest commits of both trusted sources, generates temporary
artifacts, rejects reductions in coverage or anomalous growth, runs all static
and behavioral tests, and commits only the manifest, report and runtime TSV.
If any source, validation or test step fails, the repository is unchanged and
the workflow is visibly failed.

The generator validates MCC/MNC values, APNs, selectors, field delimiters,
authentication modes and IP-family values. Output contains no timestamps and
is reproducible for identical inputs.

During an update, profiles that disappeared upstream are retained with a lower
priority. A router therefore tries new data first but can still recover through
the last known profile. Repeatedly absent profiles are progressively demoted
and capped at priority 900000 instead of being silently deleted.
