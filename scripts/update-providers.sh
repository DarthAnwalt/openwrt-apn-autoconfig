#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MANIFEST="${APN_PROVIDER_MANIFEST:-$ROOT/data/provider-sources.json}"
OUTPUT="${APN_PROVIDER_OUTPUT:-$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv}"
REPORT="${APN_PROVIDER_REPORT:-$ROOT/data/providers-report.json}"
PREVIOUS="${APN_PROVIDER_PREVIOUS:-$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv}"
VERSION_FILE="${APN_PROVIDER_VERSION_FILE:-$ROOT/apn-autoconfig-providers/VERSION}"
TMP="${TMPDIR:-/tmp}/apn-provider-update.$$"
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP"

manifest_value() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["sources"][sys.argv[2]][sys.argv[3]])' \
		"$MANIFEST" "$1" "$2"
}

fetch_source() {
	name="$1"
	destination="$TMP/$name"
	repository="$(manifest_value "$name" repository)"
	revision="$(manifest_value "$name" revision)"
	git init -q "$destination"
	git -C "$destination" remote add origin "$repository"
	git -C "$destination" fetch -q --depth 1 origin "$revision"
	git -C "$destination" checkout -q --detach FETCH_HEAD
}

fetch_source mbpi
fetch_source aosp

python3 "$ROOT/scripts/verify-provider-source-licenses.py" \
	--manifest "$MANIFEST" \
	--mbpi "$TMP/mbpi/$(manifest_value mbpi path)" \
	--aosp "$TMP/aosp/$(manifest_value aosp path)"

set -- python3 "$ROOT/scripts/generate-providers.py" \
	--mbpi "$TMP/mbpi/$(manifest_value mbpi path)" \
	--aosp "$TMP/aosp/$(manifest_value aosp path)" \
	--manifest "$MANIFEST" \
	--database-version-file "$VERSION_FILE" \
	--output "$OUTPUT" \
	--report "$REPORT"
[ ! -r "$PREVIOUS" ] || set -- "$@" --previous "$PREVIOUS"
"$@"
