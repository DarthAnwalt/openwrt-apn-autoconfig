#!/bin/sh
set -eu

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="${TMPDIR:-/tmp}/apn-autoconfig-test.$$"
MOCKBIN="$TESTROOT/bin"
STATE="$TESTROOT/state"
DB="$TESTROOT/providers.tsv"
PERSIST="$TESTROOT/persist"
CACHE="$PERSIST/cache"
SCRIPT="$BASE/files/usr/sbin/apn-autoconfig"

cleanup() {
	rm -rf "$TESTROOT"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$MOCKBIN" "$STATE" "$CACHE" "$PERSIST"

cat >"$DB" <<'EOF'
# demo
26201	-	-	01	Kaufland Mobil	Kaufland Mobil	internet.telekom	10
26201	-	-	-	-	Telekom Germany	internet.telekom	20
26202	-	-	-	-	Vodafone Germany	web.vodafone.de	10
EOF

printf '%s\n' 'old.apn' >"$STATE/apn"

cat >"$MOCKBIN/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
case "$1:$2" in
get:apn-autoconfig.main.interface) printf '%s\n' wwan ;;
get:apn-autoconfig.main.sim_index) printf '%s\n' 0 ;;
get:apn-autoconfig.main.device) printf '%s\n' wwan0 ;;
get:apn-autoconfig.main.database) printf '%s\n' "$TEST_DB" ;;
get:apn-autoconfig.main.cache_dir) printf '%s\n' "$TEST_CACHE" ;;
get:apn-autoconfig.main.state_dir) printf '%s\n' "$TEST_PERSIST" ;;
get:apn-autoconfig.main.test_url) printf '%s\n' https://example.invalid/check ;;
get:apn-autoconfig.main.wait_seconds) printf '%s\n' 2 ;;
get:apn-autoconfig.main.try_empty) printf '%s\n' 0 ;;
get:apn-autoconfig.main.use_mwan3) printf '%s\n' auto ;;
get:apn-autoconfig.main.lock_dir) printf '%s\n' "$TEST_LOCK" ;;
get:network.wwan.apn) cat "$TEST_STATE/apn" ;;
set:*)
	case "$2" in network.wwan.apn=*) printf '%s\n' "${2#network.wwan.apn=}" >"$TEST_STATE/apn" ;; *) exit 1 ;; esac
;;
delete:network.wwan.apn) rm -f "$TEST_STATE/apn" ;;
commit:network) : ;;
*) exit 1 ;;
esac
EOF

cat >"$MOCKBIN/mmcli" <<'EOF'
#!/bin/sh
printf '%s\n' \
"sim.properties.active                         : yes" \
"sim.properties.imsi                           : ${SIM_IMSI:-262014740651867}" \
"sim.properties.iccid                          : ${SIM_ICCID:-89490200002186275443}" \
"sim.properties.eid                            : ${SIM_EID:-35060000000000000026000000047063}" \
"sim.properties.operator-id                    : ${SIM_OPERATOR_ID:-26201}" \
"sim.properties.operator-name                  : ${SIM_OPERATOR_NAME:-Kaufland Mobil}" \
"sim.properties.gid1                           : ${SIM_GID1:-01}" \
"sim.properties.gid2                           : ${SIM_GID2:-FF}"
EOF

cat >"$MOCKBIN/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{ "up": true }'
EOF

cat >"$MOCKBIN/ifdown" <<'EOF'
#!/bin/sh
printf 'down %s\n' "$1" >>"$TEST_STATE/events"
EOF

cat >"$MOCKBIN/ifup" <<'EOF'
#!/bin/sh
printf 'up %s\n' "$1" >>"$TEST_STATE/events"
EOF

cat >"$MOCKBIN/mwan3" <<'EOF'
#!/bin/sh
case "$1" in
interfaces) printf '%s\n' 'interface wwan is online' ;;
use) shift 2; exec "$@" ;;
*) exit 1 ;;
esac
EOF

cat >"$MOCKBIN/curl" <<'EOF'
#!/bin/sh
current="$(cat "$TEST_STATE/apn" 2>/dev/null || :)"
[ "$current" = "${CURL_SUCCESS_APN:-internet.telekom}" ]
EOF

cat >"$MOCKBIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0755 "$MOCKBIN"/*
export PATH="$MOCKBIN:/usr/bin:/bin"
export TEST_DB="$DB" TEST_CACHE="$CACHE" TEST_STATE="$STATE" TEST_LOCK="$TESTROOT/lock" TEST_PERSIST="$PERSIST"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	haystack="$1"
	needle="$2"
	printf '%s\n' "$haystack" | grep -F -q "$needle" || fail "missing: $needle"
}

printf '%s\n' 'TEST detect is read-only and finds the specific candidate'
before="$(cat "$STATE/apn")"
detect_output="$(sh "$SCRIPT" detect 2>&1)"
assert_contains "$detect_output" 'Kaufland Mobil'
first_candidate="$(printf '%s\n' "$detect_output" | awk '/^[[:space:]]*1\./ { print; exit }')"
assert_contains "$first_candidate" 'Kaufland Mobil'
[ "$(printf '%s\n' "$detect_output" | grep -F -c 'internet.telekom')" -eq 1 ] || fail 'detect did not deduplicate identical APNs'
[ "$(cat "$STATE/apn")" = "$before" ] || fail 'detect changed APN'

printf '%s\n' 'TEST apply stores working APN and ICCID cache'
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN
sh "$SCRIPT" apply
[ "$(cat "$STATE/apn")" = 'internet.telekom' ] || fail 'working APN not kept'
[ -s "$CACHE/89490200002186275443.tsv" ] || fail 'ICCID cache missing'
grep -F -q 'internet.telekom' "$CACHE/89490200002186275443.tsv" || fail 'cache APN missing'
[ -s "$PERSIST/baseline.tsv" ] || fail 'pre-apply APN baseline missing'
[ -s "$PERSIST/active.tsv" ] || fail 'reconciled SIM state missing'

printf '%s\n' 'TEST reconcile is idempotent for an already verified SIM and APN'
: >"$STATE/events"
sh "$SCRIPT" reconcile
[ ! -s "$STATE/events" ] || fail 'idempotent reconcile restarted the interface'

printf '%s\n' 'TEST reconcile restores the cached APN when configuration differs'
printf '%s\n' 'wrong.apn' >"$STATE/apn"
: >"$STATE/events"
sh "$SCRIPT" reconcile
[ "$(cat "$STATE/apn")" = 'internet.telekom' ] || fail 'reconcile did not restore cached APN'
[ -s "$STATE/events" ] || fail 'reconcile did not restart the interface after APN change'

printf '%s\n' 'TEST changed ICCID is reconciled even when the old APN could still work'
SIM_IMSI=262023103971566
SIM_ICCID=89492031246010483050
SIM_EID=--
SIM_OPERATOR_ID=26202
SIM_OPERATOR_NAME='SIMon mobile'
SIM_GID1=FF
SIM_GID2=--
CURL_SUCCESS_APN=web.vodafone.de
export SIM_IMSI SIM_ICCID SIM_EID SIM_OPERATOR_ID SIM_OPERATOR_NAME SIM_GID1 SIM_GID2 CURL_SUCCESS_APN
: >"$STATE/events"
sh "$SCRIPT" reconcile
[ "$(cat "$STATE/apn")" = 'web.vodafone.de' ] || fail 'changed ICCID kept the previous provider APN'
grep -F -q '89492031246010483050' "$PERSIST/active.tsv" || fail 'changed ICCID was not recorded as reconciled'
[ -s "$STATE/events" ] || fail 'changed ICCID did not restart the interface'
unset SIM_IMSI SIM_ICCID SIM_EID SIM_OPERATOR_ID SIM_OPERATOR_NAME SIM_GID1 SIM_GID2
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN

printf '%s\n' 'TEST reset restores pre-apply APN and removes generated state'
sh "$SCRIPT" reset >/dev/null 2>&1
[ "$(cat "$STATE/apn")" = 'old.apn' ] || fail 'reset did not restore original APN'
[ ! -e "$PERSIST/baseline.tsv" ] || fail 'reset left baseline behind'
[ ! -e "$PERSIST/active.tsv" ] || fail 'reset left reconciled SIM state behind'
[ ! -e "$CACHE" ] || fail 'reset left cache behind'

printf '%s\n' 'TEST failed apply rolls back the previous APN'
rm -f "$CACHE/89490200002186275443.tsv"
printf '%s\n' 'rollback.apn' >"$STATE/apn"
CURL_SUCCESS_APN=never.matches
export CURL_SUCCESS_APN
if sh "$SCRIPT" apply >/dev/null 2>&1; then
	fail 'failed candidate unexpectedly succeeded'
fi
[ "$(cat "$STATE/apn")" = 'rollback.apn' ] || fail 'previous APN was not restored'

printf '%s\n' 'TEST reset after failed apply is idempotent for network state'
sh "$SCRIPT" reset >/dev/null 2>&1
[ "$(cat "$STATE/apn")" = 'rollback.apn' ] || fail 'reset changed the pre-failure APN'

printf '%s\n' 'TEST originally absent APN option is removed again by reset'
rm -f "$STATE/apn"
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN
sh "$SCRIPT" apply >/dev/null 2>&1
sh "$SCRIPT" reset >/dev/null 2>&1
[ ! -e "$STATE/apn" ] || fail 'reset left an APN option that was originally absent'
printf '%s\n' 'rollback.apn' >"$STATE/apn"

printf '%s\n' 'TEST status reports configured APN'
status_output="$(sh "$SCRIPT" status 2>&1)"
assert_contains "$status_output" 'Configured APN:  rollback.apn'

printf '%s\n' 'All tests passed.'
