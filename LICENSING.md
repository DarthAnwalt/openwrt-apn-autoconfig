# Licensing policy

This repository is a multi-license distribution. The top-level `LICENSE` does
not override the licenses of imported or generated provider data.

## Project implementation

The original shell, Python and JavaScript implementation, package definitions,
tests, workflows and project documentation are licensed under the MIT License
in `LICENSE`, unless a file says otherwise.

The manually maintained rows in `data/providers-overrides.tsv` are contributed
to the project under the same MIT terms. Their factual provenance is documented
in `docs/provider-overrides.md`.

## Provider data

The generated `providers.tsv` is a combined work containing:

- modified data derived from AOSP `device/sample/etc/apns-full-conf.xml`,
  licensed under Apache-2.0;
- transformed GNOME mobile-broadband-provider-info data carrying the Creative
  Commons Public Domain Dedication and Certification (`CC-PDDC`);
- local overrides contributed under MIT.

The provider package therefore declares `Apache-2.0 AND CC-PDDC`, while the
local contribution remains available under MIT. Exact upstream revisions are
recorded in `data/provider-sources.json` and in the generated TSV header. The
applicable texts are in `data/licenses/`, and attribution is in
`apn-autoconfig-providers/NOTICE` and `THIRD_PARTY_NOTICES.md`.

Every binary package installs its applicable license text. The provider package
also installs its third-party NOTICE.

## External runtime components

OpenWrt, LuCI, ModemManager, curl and other declared dependencies are separate
packages and are not copied into this repository's APK payloads. They remain
under their respective licenses.

## Trademarks and non-endorsement

Android is a trademark of Google LLC. GNOME is a registered trademark of the
GNOME Foundation. OpenWrt and mobile operator names and marks belong to their
respective owners. Factual references identify upstream sources, compatible
software or network providers and do not imply affiliation, sponsorship or
endorsement.
