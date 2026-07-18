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
expected_version="$(sed -n '1p' "$ROOT/apn-autoconfig-providers/VERSION")"
grep -F -q "# database-version: $expected_version" "$TMP/one.tsv"
grep -F -q '# database-format: 2' "$TMP/one.tsv"
grep -F -q '# AOSP portion: Copyright 2006, The Android Open Source Project; Apache-2.0.' "$TMP/one.tsv"
grep -F -q '# MBPI portion: Creative Commons Public Domain Dedication and Certification (CC-PDDC).' "$TMP/one.tsv"
grep -F -q '# Changes: filtered, normalized, deduplicated, merged, prioritized and converted to TSV.' "$TMP/one.tsv"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["database_version"] == sys.argv[2]; assert d["database_format"] == 2' \
	"$TMP/one.tsv.json" "$expected_version"

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

{
	printf '%s\n' '<!-- Copyright 2006, The Android Open Source Project' \
		'Licensed under the Apache License, Version 2.0 (the "License")' \
		'http://www.apache.org/licenses/LICENSE-2.0 -->'
	cat "$ROOT/tests/fixtures/aosp-apns.xml"
} >"$TMP/licensed-aosp.xml"
{
	printf '%s\n' '<!-- THIS WORK IS IN PUBLIC DOMAIN:' \
		'dedicates whatever copyright the dedicators holds' \
		'freely reproduced, distributed, transmitted, used, modified, built upon -->'
	cat "$ROOT/tests/fixtures/mbpi.xml"
} >"$TMP/licensed-mbpi.xml"
python3 "$ROOT/scripts/verify-provider-source-licenses.py" \
	--manifest "$ROOT/data/provider-sources.json" \
	--mbpi "$TMP/licensed-mbpi.xml" --aosp "$TMP/licensed-aosp.xml" >/dev/null
sed '/Copyright 2006, The Android Open Source Project/d' "$TMP/licensed-aosp.xml" \
	>"$TMP/unlicensed-aosp.xml"
if python3 "$ROOT/scripts/verify-provider-source-licenses.py" \
	--manifest "$ROOT/data/provider-sources.json" \
	--mbpi "$TMP/licensed-mbpi.xml" --aosp "$TMP/unlicensed-aosp.xml" >/dev/null 2>&1; then
	printf '%s\n' 'Provider license verifier accepted an AOSP file without attribution.' >&2
	exit 1
fi

printf '%s\n' 'Provider generator tests passed.'
