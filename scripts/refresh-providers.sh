#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/apn-provider-refresh.$$"
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP"

OLD_MANIFEST="$ROOT/data/provider-sources.json"
OLD_DATABASE="$ROOT/files/usr/share/apn-autoconfig/providers.tsv"
OLD_REPORT="$ROOT/data/providers-report.json"
NEW_MANIFEST="$TMP/provider-sources.json"
NEW_DATABASE="$TMP/providers.tsv"
NEW_REPORT="$TMP/providers-report.json"

python3 "$ROOT/scripts/refresh-provider-sources.py" \
	--manifest "$OLD_MANIFEST" --output "$NEW_MANIFEST"

APN_PROVIDER_MANIFEST="$NEW_MANIFEST" \
APN_PROVIDER_OUTPUT="$NEW_DATABASE" \
APN_PROVIDER_REPORT="$NEW_REPORT" \
APN_PROVIDER_PREVIOUS="$OLD_DATABASE" \
	sh "$ROOT/scripts/update-providers.sh"

python3 "$ROOT/scripts/check-provider-update.py" \
	--old-report "$OLD_REPORT" --new-report "$NEW_REPORT" \
	--old-database "$OLD_DATABASE" --new-database "$NEW_DATABASE"

mv "$NEW_MANIFEST" "$OLD_MANIFEST"
mv "$NEW_DATABASE" "$OLD_DATABASE"
mv "$NEW_REPORT" "$OLD_REPORT"
