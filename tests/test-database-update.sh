#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/files/usr/libexec/apn-autoconfig-database"
TMP="${TMPDIR:-/tmp}/apn-autoconfig-database-test.$$"
BIN="$TMP/bin"
STATE="$TMP/state"
DB="$TMP/providers.tsv"
INSTALLED="$TMP/installed-version"
REPOSITORIES="$TMP/repositories"
KEYS="$TMP/keys"
LOCK="$TMP/lock"

cleanup() {
	rm -rf "$TMP"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$BIN" "$KEYS"
printf '%s\n' 'test public key' >"$KEYS/apn-autoconfig.pem"
KEY_SHA256="$(sha256sum "$KEYS/apn-autoconfig.pem" | awk '{ print $1 }')"
printf '%s\n' 'https://example.invalid/apn/packages.adb' >"$REPOSITORIES"
printf '%s\n' '2026.07.16-r1' >"$INSTALLED"

write_database() {
	version="$1"
	cat >"$DB" <<EOF
# apn-autoconfig generated provider database v2
# database-version: $version
# database-format: 2
# sources: fixture
# revisions: fixture@1234567
26201	-	-	-	-	Fixture	internet	10	-	-	-	-
EOF
}
write_database 2026.07.16

cat >"$BIN/uci" <<'EOF'
#!/bin/sh
exit 1
EOF

cat >"$BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat >"$BIN/apk" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	case "$1" in
		--keys-dir|--repositories-file|--cache-dir) shift 2 ;;
		--force-refresh|--allow-untrusted) shift ;;
		*) break ;;
	esac
done
command="${1:-}"
shift || :
case "$command" in
	list)
		case " $* " in
			*' --installed '*)
				version="$(cat "$MOCK_INSTALLED")"
				printf 'apn-autoconfig-providers-%s noarch {fixture} [installed]\n' "$version"
			;;
			*' --upgradable '*)
				[ -n "${MOCK_AVAILABLE:-}" ] && \
					printf 'apn-autoconfig-providers-%s noarch {fixture} [upgradable from: %s]\n' \
						"$MOCK_AVAILABLE" "$(cat "$MOCK_INSTALLED")"
			;;
		esac
	;;
	update)
		[ "${MOCK_UPDATE_FAIL:-0}" = 0 ] || {
			printf '%s\n' 'network unavailable' >&2
			exit 1
		}
	;;
	fetch)
		while [ "$#" -gt 0 ]; do
			case "$1" in
				--output) output="$2"; shift 2 ;;
				*) shift ;;
			esac
		done
		: >"$output/apn-autoconfig-providers-$MOCK_AVAILABLE.apk"
	;;
	extract)
		while [ "$#" -gt 0 ]; do
			case "$1" in
				--destination) destination="$2"; shift 2 ;;
				*) shift ;;
			esac
		done
		mkdir -p "$destination/usr/share/apn-autoconfig"
		version="${MOCK_AVAILABLE%-r[0-9]*}"
		[ "${MOCK_INVALID_DATABASE:-0}" = 0 ] || version=invalid
		cat >"$destination/usr/share/apn-autoconfig/providers.tsv" <<EOD
# apn-autoconfig generated provider database v2
# database-version: $version
# database-format: 2
# sources: fixture
# revisions: fixture@update
26201	-	-	-	-	Fixture	updated.apn	10	-	-	-	-
EOD
	;;
	add|upgrade)
		case " $* " in *' --simulate '*) exit 0 ;; esac
		[ "${MOCK_INSTALL_FAIL:-0}" = 0 ] || {
			printf '%s\n' 'installation failed' >&2
			exit 1
		}
		printf '%s\n' "$MOCK_AVAILABLE" >"$MOCK_INSTALLED"
		version="${MOCK_AVAILABLE%-r[0-9]*}"
		cat >"$MOCK_DATABASE" <<EOD
# apn-autoconfig generated provider database v2
# database-version: $version
# database-format: 2
# sources: fixture
# revisions: fixture@installed
26201	-	-	-	-	Fixture	updated.apn	10	-	-	-	-
EOD
	;;
	*) exit 2 ;;
esac
EOF
chmod 0755 "$BIN"/*

export PATH="$BIN:$PATH"
export MOCK_INSTALLED="$INSTALLED" MOCK_DATABASE="$DB"
export APN_DATABASE_APK="$BIN/apk"
export APN_DATABASE_FILE="$DB"
export APN_DATABASE_STATE_FILE="$STATE"
export APN_DATABASE_LOCK_DIR="$LOCK"
export APN_DATABASE_REPOSITORIES_FILE="$REPOSITORIES"
export APN_DATABASE_REPOSITORIES_DIR="$TMP/no-repositories.d"
export APN_DATABASE_KEYS_DIR="$KEYS"
export APN_DATABASE_FEED_URL='https://example.invalid/apn/packages.adb'
export APN_DATABASE_KEY_SHA256="$KEY_SHA256"
export APN_DATABASE_TMP_BASE="$TMP/work"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

printf '%s\n' 'TEST database updater reports initial trust and installed metadata'
initial_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "never"; assert d["installed_package_version"] == "2026.07.16-r1"; assert d["database_version"] == "2026.07.16"; assert d["feed_configured"] is True; assert d["key_trusted"] is True; assert d["update_available"] is False' "$initial_json" || fail 'invalid initial updater status'

printf '%s\n' 'TEST database check records an up-to-date result'
MOCK_AVAILABLE='' sh "$SCRIPT" check
current_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "current"; assert d["checked_at"]; assert d["available_package_version"] == d["installed_package_version"]; assert d["update_available"] is False' "$current_json" || fail 'current database status was not recorded'

printf '%s\n' 'TEST database check and install expose and apply only the provider update'
MOCK_AVAILABLE='2026.07.18-r1'
export MOCK_AVAILABLE
sh "$SCRIPT" check
available_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "update-available"; assert d["available_package_version"] == "2026.07.18-r1"; assert d["update_available"] is True' "$available_json" || fail 'available update was not exposed'
sh "$SCRIPT" install
[ "$(cat "$INSTALLED")" = '2026.07.18-r1' ] || fail 'provider package was not installed'
installed_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "updated"; assert d["installed_package_version"] == "2026.07.18-r1"; assert d["database_version"] == "2026.07.18"; assert d["installed_at"]; assert d["update_available"] is False' "$installed_json" || fail 'successful installation was not recorded'

printf '%s\n' 'TEST invalid candidate database is rejected before package installation'
printf '%s\n' '2026.07.18-r1' >"$INSTALLED"
write_database 2026.07.18
MOCK_AVAILABLE='2026.07.19-r1'
MOCK_INVALID_DATABASE=1
export MOCK_AVAILABLE MOCK_INVALID_DATABASE
if sh "$SCRIPT" install >/dev/null 2>&1; then
	fail 'invalid provider database package was installed'
fi
[ "$(cat "$INSTALLED")" = '2026.07.18-r1' ] || fail 'invalid candidate changed the installed package'
invalid_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "install-failed"; assert d["update_available"] is True' "$invalid_json" || fail 'candidate validation failure was not recorded'
unset MOCK_INVALID_DATABASE

printf '%s\n' 'TEST repository and network failures preserve the installed database'
MOCK_UPDATE_FAIL=1
export MOCK_UPDATE_FAIL
if sh "$SCRIPT" check >/dev/null 2>&1; then fail 'failed repository refresh returned success'; fi
failure_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "check-failed"; assert "network unavailable" in d["message"]; assert d["installed_package_version"] == "2026.07.18-r1"' "$failure_json" || fail 'repository failure was not recorded safely'
unset MOCK_UPDATE_FAIL

printf '%s\n' 'TEST missing trusted key blocks update checks'
mv "$KEYS/apn-autoconfig.pem" "$KEYS/apn-autoconfig.pem.disabled"
APN_DATABASE_KEY_SHA256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
export APN_DATABASE_KEY_SHA256
if sh "$SCRIPT" check >/dev/null 2>&1; then fail 'check ran without the trusted repository key'; fi
key_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "check-failed"; assert d["key_trusted"] is False; assert "key" in d["message"].lower()' "$key_json" || fail 'missing key was not explained'

printf '%s\n' 'TEST pre-existing temporary workspace is rejected'
mv "$KEYS/apn-autoconfig.pem.disabled" "$KEYS/apn-autoconfig.pem"
APN_DATABASE_KEY_SHA256="$KEY_SHA256"
export APN_DATABASE_KEY_SHA256
mkdir -p "$TMP/work"
printf '%s\n' sentinel >"$TMP/work/sentinel"
if sh "$SCRIPT" check >/dev/null 2>&1; then
	fail 'pre-existing temporary workspace was reused'
fi
[ ! -e "$TMP/work/cache" ] || fail 'files were created inside the pre-existing workspace'
[ "$(cat "$TMP/work/sentinel")" = sentinel ] || fail 'pre-existing workspace was modified or removed'

printf '%s\n' 'Database updater tests passed.'
