#!/bin/sh
set -eu

# Verification that is safe and sufficient to run in the public provider-data
# repository. It intentionally contains no router fixture, hardware record or
# project-development test suite.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
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
database_path="apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
version="$ROOT/apn-autoconfig-providers/VERSION"
report="$ROOT/data/providers-report.json"
[ -s "$database" ] && [ -s "$version" ] && [ -s "$report" ]
grep -F -q '# sources:' "$database"
grep -F -q '# revisions:' "$database"
grep -F -q '# database-version:' "$database"

# Re-fetch the pinned public sources, re-check their licences and prove that
# the committed package input is reproducible from them and the declared
# overrides. The previous database is an explicit input because it preserves
# profiles temporarily removed upstream. Use the exact preceding public blob,
# not the new database as its own predecessor: retained rows are deliberately
# demoted once per upstream removal, so feeding the result back would demote
# them a second time and would not reproduce the update that actually ran.
previous="$WORK/previous-providers.tsv"
if git -C "$ROOT" diff --quiet -- "$database_path"; then
	database_commit="$(git -C "$ROOT" log -1 --format=%H -- "$database_path")"
	[ -n "$database_commit" ] || {
		printf 'No committed provider database exists to verify.\n' >&2
		exit 1
	}
	git -C "$ROOT" show "$database_commit^:$database_path" >"$previous" 2>/dev/null || {
		printf 'The previous provider database is absent from public history.\n' >&2
		exit 1
	}
else
	git -C "$ROOT" show "HEAD:$database_path" >"$previous"
fi
APN_PROVIDER_OUTPUT="$WORK/providers.tsv" \
APN_PROVIDER_REPORT="$WORK/providers-report.json" \
	APN_PROVIDER_PREVIOUS="$previous" \
	sh "$ROOT/scripts/update-providers.sh"
cmp "$database" "$WORK/providers.tsv"
cmp "$report" "$WORK/providers-report.json"

sh "$ROOT/scripts/check-public-safe.sh"
printf 'Provider update pipeline verified.\n'
