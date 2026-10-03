#!/bin/sh
set -eu

# Verification that is safe and sufficient to run in the public provider-data
# repository. It intentionally contains no router fixture, hardware record or
# project-development test suite.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# These paths and format are external interfaces, including for consumers
# which fetch raw main. An incompatible format needs a different URL.
check_database() {
	python3 - "$1" <<'CHECK_DATABASE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
expected = '# mccmnc  imsi_pattern  iccid_pattern  gid1  spn  provider  apn  priority  username  password  auth  ip_type'
try:
    lines = p.read_text(encoding='utf-8').splitlines()
    if '# database-format: 2' not in lines:
        raise ValueError('format must remain 2')
    if expected not in lines:
        raise ValueError('column order must remain compatible')
    rows = [line.split('\t') for line in lines if line and not line.startswith('#')]
    if not rows or any(len(row) != 12 for row in rows):
        raise ValueError('expected twelve TAB fields')
    if any(not all(row) for row in rows):
        raise ValueError('use - for unspecified values')
except (OSError, UnicodeError, ValueError) as error:
    sys.exit('Provider compatibility check failed: ' + str(error))
CHECK_DATABASE
}

case "${1:-}" in
	--site)
		site="${2:?a site directory is required}"
		check_database "$site/providers/providers.tsv"
		for file in providers.tsv NOTICE Apache-2.0.txt MBPI-CC-PDDC.txt README.txt; do
			[ -s "$site/providers/$file" ] || exit 1
		done
		python3 - "$site" <<'CHECK_SITE'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
checksums = {}
for line in (root / 'SHA256SUMS').read_text().splitlines():
    digest, name = line.split(maxsplit=1)
    checksums[name.lstrip('*')] = digest
for name in ('providers.tsv', 'NOTICE', 'Apache-2.0.txt', 'MBPI-CC-PDDC.txt', 'README.txt'):
    path = 'providers/' + name
    if checksums.get(path) != hashlib.sha256((root / path).read_bytes()).hexdigest():
        sys.exit('Provider checksum missing or mismatched: ' + path)
CHECK_SITE
		exit 0
	;;
	''|--contract-only) : ;;
	*) printf 'Usage: %s [--contract-only | --site DIR]\n' "$0" >&2; exit 2 ;;
esac
check_database "$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
[ "${1:-}" != --contract-only ] || exit 0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apn-provider-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

for script in \
	refresh-providers.sh update-providers.sh build-provider-with-sdk.sh \
	build-repository.sh publish-feed.sh check-public-safe.sh \
	check-release-artifacts.sh
do
	sh -n "$ROOT/scripts/$script"
done
python3 -m json.tool "$ROOT/data/provider-sources.json" >/dev/null
python3 -m json.tool "$ROOT/data/providers-report.json" >/dev/null
PYTHONPYCACHEPREFIX="$WORK/pycache" python3 -m py_compile \
	"$ROOT/scripts/generate-providers.py" \
	"$ROOT/scripts/refresh-provider-sources.py" \
	"$ROOT/scripts/check-provider-update.py" \
	"$ROOT/scripts/fetch-published-packages.py" \
	"$ROOT/scripts/verify-provider-source-licenses.py"

database="$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
previous="$ROOT/data/providers-previous.tsv"
version="$ROOT/apn-autoconfig-providers/VERSION"
report="$ROOT/data/providers-report.json"
[ -s "$database" ] && [ -s "$previous" ] && [ -s "$version" ] && [ -s "$report" ]
grep -F -q '# sources:' "$database"
grep -F -q '# revisions:' "$database"
grep -F -q '# database-version:' "$database"

# Re-fetch the pinned public sources, re-check their licences and prove that
# the committed package input is reproducible from them and the declared
# overrides. The previous database is an explicit input because it preserves
# profiles temporarily removed upstream. The exact predecessor is committed as
# a public input instead of being recovered from Git ancestry: retained rows
# are deliberately demoted once per upstream removal, so the current result
# cannot be fed back as its own predecessor.
APN_PROVIDER_OUTPUT="$WORK/providers.tsv" \
APN_PROVIDER_REPORT="$WORK/providers-report.json" \
	APN_PROVIDER_PREVIOUS="$previous" \
	sh "$ROOT/scripts/update-providers.sh"
cmp "$database" "$WORK/providers.tsv"
cmp "$report" "$WORK/providers-report.json"

sh "$ROOT/scripts/check-public-safe.sh"
printf 'Provider update pipeline verified.\n'
