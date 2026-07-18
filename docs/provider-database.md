# Provider database v2

The provider database is a generated, compact runtime artifact installed by the
independently versioned `apn-autoconfig-providers` package. The large upstream
XML files are deliberately not installed on the router.

## Sources

- GNOME `mobile-broadband-provider-info` (MBPI) is the preferred source. Its
  database is dedicated to the public domain and is actively maintained.
- AOSP `device/sample/etc/apns-full-conf.xml` supplements MBPI with additional
  MCC/MNC coverage and MVNO selectors. It is licensed under Apache-2.0.
- `data/providers-overrides.tsv` contains manually verified corrections and
  receives the highest priority. Its evidence log is
  `docs/provider-overrides.md`.

Exact upstream revisions are pinned in `data/provider-sources.json`. Normal
OpenWrt package builds and router runtime therefore never fetch network data.
The generator records the transformation notice and AOSP copyright in the TSV;
the provider APK includes the complete Apache-2.0 and CC-PDDC texts and a
third-party NOTICE.

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

The comment header contains machine-readable metadata:

```text
# database-version: 2026.07.18
# database-format: 2
# sources: mbpi, aosp, local overrides
# revisions: mbpi@..., aosp@...
```

The database uses a date-based `YYYY.MM.DD-rN` package version independent from
the core. Updates that keep format v2 do not require a new core or LuCI package.
An explicitly declared unsupported format is rejected before any modem or
network operation.

## Manual update through LuCI

LuCI 0.4.1 can check and install this package independently from the core. The
updater requires the project feed to be present in APK's repository
configuration and the pinned project public key to exist in APK's trusted key
directory. It never downloads a raw TSV, and the actual APK transaction never
uses `--allow-untrusted`.

Each check builds a temporary repository configuration containing only the
already configured project feed. If an update exists, installation refreshes
that repository again, fetches the candidate package through its signed index,
extracts it into `/tmp`, and verifies the declared v2 format, matching
date-based package version and all runtime row fields before asking APK to
upgrade only `apn-autoconfig-providers`. APK remains responsible for the final
transaction. No mobile profile or interface is changed by a database update.

The repository index authenticates the checksum of the fetched package.
OpenWrt package payloads in this feed are not individually signed, so the
standalone pre-install extraction uses `apk --allow-untrusted extract` only
after the package has been fetched through that trusted index. Neither fetch
nor installation permits an untrusted repository or package.

The updater uses the same operation lock as APN reconciliation and modem
control. Its persistent state records only versions, timestamps and a sanitized
result message in `/etc/apn-autoconfig/database-update.tsv`.

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
quality report. It is never run during package builds. Before committing a
manual database-content change, set `apn-autoconfig-providers/VERSION` to the
new `YYYY.MM.DD` version; the verification suite requires the package, TSV
header and quality report to agree.

The `Update provider database` GitHub Actions workflow runs every Monday. It
resolves the latest commits of both trusted sources, generates temporary
artifacts, rejects reductions in coverage or anomalous growth, runs all static
and behavioral tests, and commits only the manifest, report, database version
and runtime TSV.
If any source, validation or test step fails, the repository is unchanged and
the workflow is visibly failed.

## Supply-chain trust

MBPI and AOSP are trusted data sources within the automated validation limits.
The anomaly checks detect malformed input, reduced coverage and unusually large
growth, but cannot prove that every syntactically valid APN profile is correct.
A subtle upstream change that remains within those limits can therefore be
included in an automatically generated and signed provider package. The pinned
source revisions committed in `data/provider-sources.json` are the audit trail
for each update. Package signatures authenticate what this project published;
they do not independently attest to the correctness of every upstream row.

The generator validates MCC/MNC values, APNs, selectors, field delimiters,
authentication modes and IP-family values. Output contains no generation
timestamp and is reproducible for identical inputs and database version.

During an update, profiles that disappeared upstream are retained with a lower
priority. A router therefore tries new data first but can still recover through
the last known profile. Repeatedly absent profiles are progressively demoted
and capped at priority 900000 instead of being silently deleted.
Whenever at least one such fallback remains, the generator carries forward the
previous database's revision list into the new TSV header. The installed file
therefore retains an audit trail for historical source revisions still capable
of contributing rows, rather than reporting only the newest upstream commits.
