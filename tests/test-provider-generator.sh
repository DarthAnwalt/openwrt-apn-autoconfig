#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/apn-provider-generator-test.$$"
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP"

generate() {
	python3 "$ROOT/scripts/generate-providers.py" \
		--mbpi "$ROOT/tests/fixtures/mbpi.xml" \
		--aosp "$ROOT/tests/fixtures/aosp-apns.xml" \
		--overrides "$ROOT/tests/fixtures/overrides.tsv" \
		--output "$1" --report "$1.json" >/dev/null 2>&1
}

generate "$TMP/one.tsv"
generate "$TMP/two.tsv"
cmp "$TMP/one.tsv" "$TMP/two.tsv"

python3 "$ROOT/scripts/generate-providers.py" \
	--mbpi "$ROOT/tests/fixtures/mbpi.xml" \
	--aosp "$ROOT/tests/fixtures/aosp-apns.xml" \
	--overrides "$ROOT/tests/fixtures/overrides.tsv" \
	--previous "$TMP/one.tsv" \
	--output "$TMP/no-op.tsv" --report "$TMP/no-op.json" >/dev/null 2>&1
cmp "$TMP/one.tsv" "$TMP/no-op.tsv"
cmp "$TMP/one.tsv.json" "$TMP/no-op.json"

[ "$(awk -F '\t' '!/^#/ && NF { count++ } END { print count + 0 }' "$TMP/one.tsv")" -eq 3 ]
grep -F -q '99901	-	-	-	-	Fixture Mobile	fixture.net	100	fixture	secret	pap	-' "$TMP/one.tsv"
grep -F -q '99901	99901x2	-	-	-	Fixture MVNO	mvno.net' "$TMP/one.tsv"
! grep -F -q 'fixture.mms' "$TMP/one.tsv"
! grep -F -q '	ims	' "$TMP/one.tsv"

python3 "$ROOT/scripts/generate-providers.py" \
	--mbpi "$ROOT/tests/fixtures/mbpi-empty.xml" \
	--aosp "$ROOT/tests/fixtures/aosp-apns.xml" \
	--overrides "$ROOT/tests/fixtures/overrides.tsv" \
	--previous "$TMP/one.tsv" \
	--output "$TMP/fallback.tsv" --report "$TMP/fallback.json" >/dev/null 2>&1
awk -F '\t' '$6 == "Fixture Mobile" && $7 == "fixture.net" && $8 == "50100" { found=1 }
	END { exit !found }' "$TMP/fallback.tsv"

python3 "$ROOT/scripts/check-provider-update.py" \
	--old-report "$TMP/one.tsv.json" --new-report "$TMP/fallback.json" \
	--old-database "$TMP/one.tsv" --new-database "$TMP/fallback.tsv" >/dev/null

printf '%s\n' 'Provider generator tests passed.'
