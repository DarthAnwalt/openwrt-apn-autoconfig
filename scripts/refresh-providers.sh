#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/apn-provider-refresh.$$"
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP"

OLD_MANIFEST="$ROOT/data/provider-sources.json"
OLD_DATABASE="$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
PREVIOUS_SNAPSHOT="$ROOT/data/providers-previous.tsv"
OLD_REPORT="$ROOT/data/providers-report.json"
OLD_VERSION="$ROOT/apn-autoconfig-providers/VERSION"
NEW_MANIFEST="$TMP/provider-sources.json"
NEW_DATABASE="$TMP/providers.tsv"
NEW_REPORT="$TMP/providers-report.json"
NEW_VERSION="$TMP/VERSION"

python3 "$ROOT/scripts/refresh-provider-sources.py" \
	--manifest "$OLD_MANIFEST" --output "$NEW_MANIFEST"

# With unchanged upstream revisions, keep the same explicit predecessor.
# Feeding the current database back would demote retained fallbacks again.
previous="$OLD_DATABASE"
if cmp -s "$OLD_MANIFEST" "$NEW_MANIFEST"; then
	previous="$PREVIOUS_SNAPSHOT"
fi

new_version="$(date -u +%Y.%m.%d)"
old_version="$(sed -n '1p' "$OLD_VERSION")"
printf '%s\n' "$new_version" >"$NEW_VERSION"

APN_PROVIDER_MANIFEST="$NEW_MANIFEST" \
APN_PROVIDER_OUTPUT="$NEW_DATABASE" \
APN_PROVIDER_REPORT="$NEW_REPORT" \
APN_PROVIDER_PREVIOUS="$previous" \
APN_PROVIDER_VERSION_FILE="$NEW_VERSION" \
	sh "$ROOT/scripts/update-providers.sh"

# A local override is an input even when both upstream HEADs stay unchanged.
# Ignore only the proposed date when deciding whether a new package is needed.
if cmp -s "$OLD_MANIFEST" "$NEW_MANIFEST" &&
	python3 - "$OLD_DATABASE" "$NEW_DATABASE" "$OLD_REPORT" "$NEW_REPORT" <<'COMPARE'
import json, pathlib, sys
def rows(path):
    return [line for line in pathlib.Path(path).read_text().splitlines()
            if not line.startswith('# database-version:')]
def report(path):
    data = json.loads(pathlib.Path(path).read_text())
    data.pop('database_version')
    return data
sys.exit(0 if rows(sys.argv[1]) == rows(sys.argv[2]) and
         report(sys.argv[3]) == report(sys.argv[4]) else 1)
COMPARE
then
	printf '%s\n' 'Provider sources and local overrides are already current.'
	exit 0
fi
[ "$new_version" != "$old_version" ] || {
	printf 'A second provider update on %s requires a package release bump.\n' "$new_version" >&2
	exit 1
}

python3 "$ROOT/scripts/check-provider-update.py" \
	--old-report "$OLD_REPORT" --new-report "$NEW_REPORT" \
	--old-database "$OLD_DATABASE" --new-database "$NEW_DATABASE"

# Keep the exact predecessor as an explicit public build input. Reproducibility
# must not depend on repository ancestry: public release snapshots deliberately
# have compact, rewritten history, and a forced rebuild must work from a clone.
if [ "$previous" = "$OLD_DATABASE" ]; then
	cp "$OLD_DATABASE" "$PREVIOUS_SNAPSHOT"
fi
mv "$NEW_MANIFEST" "$OLD_MANIFEST"
mv "$NEW_DATABASE" "$OLD_DATABASE"
mv "$NEW_REPORT" "$OLD_REPORT"
mv "$NEW_VERSION" "$OLD_VERSION"
