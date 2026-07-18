#!/bin/sh
set -eu

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="${TMPDIR:-/tmp}/apn-autoconfig-test.$$"
TEST_ACTION_STATE="/tmp/apn-autoconfig-action-test.$$"
MOCKBIN="$TESTROOT/bin"
STATE="$TESTROOT/state"
DB="$TESTROOT/providers.tsv"
PERSIST="$TESTROOT/persist"
CACHE="$PERSIST/cache"
SCRIPT="$BASE/files/usr/sbin/apn-autoconfig"
BOOT_SCRIPT="$BASE/files/usr/libexec/apn-autoconfig-boot"
BUTTON_SCRIPT="$BASE/files/etc/hotplug.d/button/50-apn-autoconfig"

cleanup() {
	rm -rf "$TESTROOT" "$TEST_ACTION_STATE" "$TEST_ACTION_STATE.start-lock"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$MOCKBIN" "$STATE" "$CACHE" "$PERSIST"
mkdir -p "$TESTROOT/sys/class/gpio/modem_power"
printf '%s\n' '0' >"$TESTROOT/sys/class/gpio/modem_power/value"

cat >"$DB" <<'EOF'
# apn-autoconfig generated provider database v2
# database-version: 2026.07.16
# database-format: 2
# sources: fixture
# revisions: fixture@1234567
26201	-	-	01	Kaufland Mobil	Kaufland Mobil	internet.telekom	10	fixture-user	fixture-pass	pap-or-chap	ipv4v6
26201	-	-	-	-	Telekom Germany	internet.telekom	20
26202	-	-	-	-	Vodafone Germany	web.vodafone.de	10
21403	2140352xxxxxxxx	-	-	-	Pattern MVNO	pattern.example	10
EOF

printf '%s\n' 'old.apn' >"$STATE/apn"
printf '%s\n' 'old-user' >"$STATE/username"
printf '%s\n' 'old-pass' >"$STATE/password"
printf '%s\n' 'chap' >"$STATE/allowedauth"
printf '%s\n' 'ipv4' >"$STATE/iptype"

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
get:apn-autoconfig.main.test_url) printf '%s\n' "${TEST_CONFIG_URL:-https://example.invalid/check}" ;;
get:apn-autoconfig.main.wait_seconds) printf '%s\n' 2 ;;
get:apn-autoconfig.main.registration_wait_seconds) printf '%s\n' "${TEST_REGISTRATION_WAIT_SECONDS:-2}" ;;
get:apn-autoconfig.main.try_empty) printf '%s\n' 0 ;;
get:apn-autoconfig.main.use_mwan3) printf '%s\n' auto ;;
get:apn-autoconfig.main.lock_dir) printf '%s\n' "$TEST_LOCK" ;;
get:apn-autoconfig.main.action_state_dir) printf '%s\n' "$TEST_ACTION_STATE" ;;
get:apn-autoconfig.main.autostart) printf '%s\n' "${TEST_AUTOSTART:-0}" ;;
get:apn-autoconfig.main.boot_delay) printf '%s\n' "${TEST_BOOT_DELAY:-0}" ;;
get:apn-autoconfig.main.boot_attempts) printf '%s\n' "${TEST_BOOT_ATTEMPTS:-3}" ;;
get:apn-autoconfig.main.retry_seconds) printf '%s\n' "${TEST_RETRY_SECONDS:-0}" ;;
get:apn-autoconfig.main.button_enabled) printf '%s\n' "${TEST_BUTTON_ENABLED:-0}" ;;
get:apn-autoconfig.main.button_name) printf '%s\n' BTN_0 ;;
get:apn-autoconfig.main.modem_power_path) printf '%s\n' "$TEST_GPIO" ;;
get:apn-autoconfig.main.modem_power_off_value) printf '%s\n' 1 ;;
get:apn-autoconfig.main.modem_power_on_value) printf '%s\n' 0 ;;
get:apn-autoconfig.main.modem_power_off_seconds) printf '%s\n' 1 ;;
get:apn-autoconfig.main.modem_wait_seconds) printf '%s\n' 3 ;;
get:apn-autoconfig.main.modem_poll_seconds) printf '%s\n' 1 ;;
get:network.wwan.device) printf '%s\n' '/sys/devices/mock-modem' ;;
get:network.wwan.apn) cat "$TEST_STATE/apn" ;;
get:network.wwan.username) cat "$TEST_STATE/username" ;;
get:network.wwan.password) cat "$TEST_STATE/password" ;;
get:network.wwan.allowedauth) cat "$TEST_STATE/allowedauth" ;;
get:network.wwan.iptype) cat "$TEST_STATE/iptype" ;;
get:network.wwan.allow_roaming) cat "$TEST_STATE/allow_roaming" ;;
get:network.wwan.plmn) cat "$TEST_STATE/plmn" ;;
set:*)
	case "$2" in
		network.wwan.*=*)
			option="${2#network.wwan.}"
			value="${option#*=}"
			option="${option%%=*}"
			case "$option" in apn|username|password|allowedauth|iptype|allow_roaming) printf '%s\n' "$value" >"$TEST_STATE/$option" ;; *) exit 1 ;; esac
		;;
		*) exit 1 ;;
	esac
;;
delete:network.wwan.apn) rm -f "$TEST_STATE/apn" ;;
delete:network.wwan.username) rm -f "$TEST_STATE/username" ;;
delete:network.wwan.password) rm -f "$TEST_STATE/password" ;;
delete:network.wwan.allowedauth) rm -f "$TEST_STATE/allowedauth" ;;
delete:network.wwan.iptype) rm -f "$TEST_STATE/iptype" ;;
delete:network.wwan.allow_roaming) rm -f "$TEST_STATE/allow_roaming" ;;
commit:network) : ;;
*) exit 1 ;;
esac
EOF

cat >"$MOCKBIN/mmcli" <<'EOF'
#!/bin/sh
[ "${MMCLI_UNAVAILABLE:-0}" = "1" ] && exit 1
case "${1:-}" in
-L)
	printf '%s\n' "    /org/freedesktop/ModemManager1/Modem/${MM_MODEM_INDEX:-7} [Quectel] RM520N-GL"
	exit 0
	;;
-m)
	registration_state="${MM_REGISTRATION_STATE:-home}"
	if [ -n "${MM_REGISTRATION_AFTER_IFUP:-}" ] && [ -e "$TEST_STATE/ifup-seen" ]; then
		registration_state="$MM_REGISTRATION_AFTER_IFUP"
	fi
	printf '%s\n' \
		"modem.generic.device : /sys/devices/mock-modem" \
		"modem.generic.physdev : /sys/devices/mock-modem" \
		"modem.generic.sim : /org/freedesktop/ModemManager1/SIM/${MM_SIM_INDEX:-9}" \
		"modem.generic.state : ${MM_MODEM_STATE:-connected}" \
		"modem.generic.access-technologies.length : 2" \
		"modem.generic.access-technologies.value[1] : lte" \
		"modem.generic.access-technologies.value[2] : 5gnr" \
		"modem.generic.signal-quality.value : 81" \
		"modem.3gpp.registration-state : $registration_state" \
		"modem.3gpp.operator-code : ${MM_SERVING_OPERATOR_ID:-26201}" \
		"modem.3gpp.operator-name : ${MM_SERVING_OPERATOR_NAME:-Telekom Test}"
	exit 0
	;;
-i)
	[ "${2:-}" = "${MM_SIM_INDEX:-9}" ] || exit 1
	;;
*) exit 1 ;;
esac
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
if [ "${UBUS_UP_AFTER_IFUP:-0}" = 1 ] && [ -e "$TEST_STATE/ifup-seen" ]; then
	printf '%s\n' '{ "up": true }'
elif [ "${UBUS_UP:-1}" = 1 ]; then
	printf '%s\n' '{ "up": true }'
else
	printf '%s\n' '{ "up": false }'
fi
EOF

cat >"$MOCKBIN/ifdown" <<'EOF'
#!/bin/sh
printf 'down %s\n' "$1" >>"$TEST_STATE/events"
EOF

cat >"$MOCKBIN/ifup" <<'EOF'
#!/bin/sh
printf 'up %s\n' "$1" >>"$TEST_STATE/events"
touch "$TEST_STATE/ifup-seen"
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

cat >"$MOCKBIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0755 "$MOCKBIN"/*
export PATH="$MOCKBIN:/usr/bin:/bin"
export TEST_DB="$DB" TEST_CACHE="$CACHE" TEST_STATE="$STATE" TEST_LOCK="$TESTROOT/lock" TEST_PERSIST="$PERSIST"
export TEST_GPIO="$TESTROOT/sys/class/gpio/modem_power/value"
export APN_AUTOCONFIG_SYSFS_ROOT="$TESTROOT/sys"

cat >"$MOCKBIN/apn-autoconfig-command" <<'EOF'
#!/bin/sh
[ "${1:-}" = "reconcile" ] || exit 2
if [ "${BLOCK_ACTION:-0}" = "1" ]; then
	while [ ! -e "$TEST_STATE/action-release" ]; do
		/bin/sleep 1
	done
fi
[ "${ACTION_EXIT:-0}" -eq 0 ] || exit "$ACTION_EXIT"
count="$(cat "$TEST_STATE/boot-calls" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" >"$TEST_STATE/boot-calls"
[ "$count" -ge "${BOOT_SUCCESS_AT:-1}" ] || exit 3
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-command"
export APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-command"
export TEST_ACTION_STATE

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_contains() {
	haystack="$1"
	needle="$2"
	printf '%s\n' "$haystack" | grep -F -q "$needle" || fail "missing: $needle"
}

printf '%s\n' 'TEST connectivity URL rejects non-HTTP schemes'
if invalid_url_output="$(TEST_CONFIG_URL=file:///etc/passwd sh "$SCRIPT" status 2>&1)"; then
	fail 'file URL was accepted as a connectivity test endpoint'
fi
assert_contains "$invalid_url_output" 'test_url must be an http(s) URL'

printf '%s\n' 'TEST detect is read-only and finds the specific candidate'
before="$(cat "$STATE/apn")"
detect_output="$(sh "$SCRIPT" detect 2>&1)"
assert_contains "$detect_output" 'Kaufland Mobil'
assert_contains "$detect_output" 'SIM index:       9'
first_candidate="$(printf '%s\n' "$detect_output" | awk '/^[[:space:]]*1\./ { print; exit }')"
assert_contains "$first_candidate" 'Kaufland Mobil'
[ "$(printf '%s\n' "$detect_output" | grep -F -c 'internet.telekom')" -eq 2 ] || \
	fail 'detect collapsed distinct authentication profiles or emitted an unexpected duplicate'
[ "$(cat "$STATE/apn")" = "$before" ] || fail 'detect changed APN'

printf '%s\n' 'TEST detect supports AOSP-style IMSI digit masks'
SIM_IMSI=214035212345678
SIM_ICCID=8952000000000000000
SIM_OPERATOR_ID=21403
SIM_OPERATOR_NAME='Pattern MVNO'
SIM_GID1=FF
export SIM_IMSI SIM_ICCID SIM_OPERATOR_ID SIM_OPERATOR_NAME SIM_GID1
pattern_output="$(sh "$SCRIPT" detect 2>&1)"
assert_contains "$pattern_output" 'pattern.example'
unset SIM_IMSI SIM_ICCID SIM_OPERATOR_ID SIM_OPERATOR_NAME SIM_GID1

printf '%s\n' 'TEST apply stores working APN and ICCID cache'
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN
sh "$SCRIPT" apply
[ "$(cat "$STATE/apn")" = 'internet.telekom' ] || fail 'working APN not kept'
[ "$(cat "$STATE/username")" = 'fixture-user' ] || fail 'working username not kept'
[ "$(cat "$STATE/password")" = 'fixture-pass' ] || fail 'working password not kept'
[ "$(cat "$STATE/allowedauth")" = 'pap chap' ] || fail 'working authentication not kept'
[ "$(cat "$STATE/iptype")" = 'ipv4v6' ] || fail 'working IP type not kept'
[ -s "$CACHE/89490200002186275443.tsv" ] || fail 'ICCID cache missing'
grep -F -q 'internet.telekom' "$CACHE/89490200002186275443.tsv" || fail 'cache APN missing'
grep -F -q 'fixture-user' "$CACHE/89490200002186275443.tsv" || fail 'cache profile missing'
[ -s "$PERSIST/baseline.tsv" ] || fail 'pre-apply APN baseline missing'
[ -s "$PERSIST/active.tsv" ] || fail 'reconciled SIM state missing'

printf '%s\n' 'TEST a matching cached profile refreshes its provider label from the database'
printf 'v2\tinternet.telekom\tLegacy provider label\t2026-01-01T00:00:00Z\t-\t-\t-\t-\n' \
	>"$CACHE/89490200002186275443.tsv"
cache_refresh_output="$(sh "$SCRIPT" apply 2>&1)"
grep -F -q 'Telekom Germany' "$CACHE/89490200002186275443.tsv" || \
	fail "matching cached profile kept a stale provider label: $cache_refresh_output; $(cat "$CACHE/89490200002186275443.tsv")"

printf '%s\n' 'TEST reconcile is idempotent for an already verified SIM and APN'
: >"$STATE/events"
sh "$SCRIPT" reconcile
[ ! -s "$STATE/events" ] || fail 'idempotent reconcile restarted the interface'

printf '%s\n' 'TEST reconcile restores the cached APN when configuration differs'
printf '%s\n' 'wrong.apn' >"$STATE/apn"
: >"$STATE/events"
sh "$SCRIPT" reconcile
[ "$(cat "$STATE/apn")" = 'internet.telekom' ] || fail 'reconcile did not restore cached APN'
[ ! -e "$STATE/username" ] || fail 'credential-free cached profile left a stale username'
[ ! -e "$STATE/password" ] || fail 'credential-free cached profile left a stale password'
[ ! -e "$STATE/allowedauth" ] || fail 'credential-free cached profile left stale authentication'
[ ! -e "$STATE/iptype" ] || fail 'credential-free cached profile left a stale IP type'
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
[ "$(cat "$STATE/username")" = 'old-user' ] || fail 'reset did not restore original username'
[ "$(cat "$STATE/password")" = 'old-pass' ] || fail 'reset did not restore original password'
[ "$(cat "$STATE/allowedauth")" = 'chap' ] || fail 'reset did not restore original authentication'
[ "$(cat "$STATE/iptype")" = 'ipv4' ] || fail 'reset did not restore original IP type'
[ ! -e "$PERSIST/baseline.tsv" ] || fail 'reset left baseline behind'
[ ! -e "$PERSIST/active.tsv" ] || fail 'reset left reconciled SIM state behind'
[ ! -e "$CACHE" ] || fail 'reset left cache behind'

printf '%s\n' 'TEST a v0.5 cache preserves the optional values of its working profile'
mkdir -p "$CACHE"
printf 'v1\tinternet.telekom\tlegacy cache\t2026-01-01T00:00:00Z\n' >"$CACHE/89490200002186275443.tsv"
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN
sh "$SCRIPT" apply >/dev/null 2>&1
[ "$(cat "$STATE/username")" = 'old-user' ] || fail 'v1 cache migration removed username'
[ "$(cat "$STATE/password")" = 'old-pass' ] || fail 'v1 cache migration removed password'
[ "$(cat "$STATE/allowedauth")" = 'chap' ] || fail 'v1 cache migration changed authentication'
[ "$(cat "$STATE/iptype")" = 'ipv4' ] || fail 'v1 cache migration changed IP type'
grep -F -q 'v2' "$CACHE/89490200002186275443.tsv" || fail 'v1 cache was not upgraded'
sh "$SCRIPT" reset >/dev/null 2>&1

printf '%s\n' 'TEST a v0.5 APN baseline is migrated without losing optional profile values'
printf 'v1\twwan\t1\tlegacy.apn\n' >"$PERSIST/baseline.tsv"
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN
sh "$SCRIPT" apply >/dev/null 2>&1
grep -F -q 'v2' "$PERSIST/baseline.tsv" || fail 'legacy baseline was not migrated'
sh "$SCRIPT" reset >/dev/null 2>&1
[ "$(cat "$STATE/apn")" = 'legacy.apn' ] || fail 'migrated baseline lost its original APN'
[ "$(cat "$STATE/username")" = 'old-user' ] || fail 'migrated baseline lost its username'
[ "$(cat "$STATE/password")" = 'old-pass' ] || fail 'migrated baseline lost its password'
[ "$(cat "$STATE/allowedauth")" = 'chap' ] || fail 'migrated baseline lost authentication'
[ "$(cat "$STATE/iptype")" = 'ipv4' ] || fail 'migrated baseline lost IP type'

printf '%s\n' 'TEST failed apply rolls back the previous APN'
rm -f "$CACHE/89490200002186275443.tsv"
printf '%s\n' 'rollback.apn' >"$STATE/apn"
CURL_SUCCESS_APN=never.matches
export CURL_SUCCESS_APN
if sh "$SCRIPT" apply >/dev/null 2>&1; then
	fail 'failed candidate unexpectedly succeeded'
fi
[ "$(cat "$STATE/apn")" = 'rollback.apn' ] || fail 'previous APN was not restored'
[ "$(cat "$STATE/username")" = 'old-user' ] || fail 'previous username was not restored'
[ "$(cat "$STATE/password")" = 'old-pass' ] || fail 'previous password was not restored'
[ "$(cat "$CACHE/last-result-code")" = 'connectivity-failed' ] || fail 'bearer-up Internet failure was not classified'

printf '%s\n' 'TEST profiles that never produce a bearer are classified separately'
UBUS_UP=0
export UBUS_UP
if sh "$SCRIPT" apply >/dev/null 2>&1; then fail 'bearer-rejected apply unexpectedly succeeded'; fi
[ "$(cat "$CACHE/last-result-code")" = 'bearer-rejected' ] || fail 'missing bearer was not classified'
unset UBUS_UP

printf '%s\n' 'TEST reset after failed apply is idempotent for network state'
sh "$SCRIPT" reset >/dev/null 2>&1
[ "$(cat "$STATE/apn")" = 'rollback.apn' ] || fail 'reset changed the pre-failure APN'

printf '%s\n' 'TEST originally absent APN option is removed again by reset'
rm -f "$STATE/apn"
printf '%s\n' 1 >"$STATE/allow_roaming"
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN
sh "$SCRIPT" apply >/dev/null 2>&1
sh "$SCRIPT" reset >/dev/null 2>&1
[ ! -e "$STATE/apn" ] || fail 'reset left an APN option that was originally absent'
[ "$(cat "$STATE/allow_roaming")" = 1 ] || fail 'APN reset changed the canonical roaming policy'
rm -f "$STATE/allow_roaming"
printf '%s\n' 'rollback.apn' >"$STATE/apn"

printf '%s\n' 'TEST status reports configured APN'
status_output="$(sh "$SCRIPT" status 2>&1)"
assert_contains "$status_output" 'Configured APN:  rollback.apn'
assert_contains "$status_output" 'APN database:    2026.07.16 (format v2)'

printf '%s\n' 'TEST machine-readable status and detect output are valid JSON'
status_json="$(sh "$SCRIPT" status-json)"
detect_json="$(sh "$SCRIPT" detect-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["version"] == "v2"; assert d["configured_apn"] == "rollback.apn"; assert d["interface_up"] is True; assert d["registration_state"] == "home"; assert d["roaming"] is False; assert d["roaming_policy"] == "default-allow"; assert d["serving_operator_id"] == "26201"; assert d["database_version"] == "2026.07.16"; assert d["database_format"] == "2"; assert d["database_sources"] == "fixture"; assert d["database_revisions"] == "fixture@1234567"; assert d["database_path"] == sys.argv[2]' "$status_json" "$DB" || fail 'invalid status JSON'
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["version"] == "v2"; assert d["iccid"] == "89490200002186275443"; assert d["database_version"] == "2026.07.16"; assert len(d["candidates"]) == 2; assert all(x["apn"] == "internet.telekom" for x in d["candidates"]); assert d["candidates"][0]["provider"] == "Kaufland Mobil"; assert d["candidates"][0]["username_required"] is True; assert d["candidates"][0]["authentication"] == "pap-or-chap"; assert d["candidates"][0]["ip_type"] == "ipv4v6"' "$detect_json" || fail 'invalid detect JSON'

printf '%s\n' 'TEST an explicitly unsupported provider database format is rejected'
awk '{ if ($0 == "# database-format: 2") print "# database-format: 3"; else print }' "$DB" >"$DB.new"
mv "$DB.new" "$DB"
if unsupported_output="$(sh "$SCRIPT" status-json 2>&1)"; then
	fail 'unsupported provider database format was accepted'
fi
assert_contains "$unsupported_output" 'unsupported provider database format: 3'
awk '{ if ($0 == "# database-format: 3") print "# database-format: 2"; else print }' "$DB" >"$DB.new"
mv "$DB.new" "$DB"

printf '%s\n' 'TEST roaming status separates the home SIM from the serving network'
MM_REGISTRATION_STATE=roaming
MM_SERVING_OPERATOR_ID=26201
MM_SERVING_OPERATOR_NAME='Telekom.de'
SIM_OPERATOR_ID=25506
SIM_OPERATOR_NAME=lifecell
SIM_IMSI=255065009019805
SIM_ICCID=89380062300756308069
export MM_REGISTRATION_STATE MM_SERVING_OPERATOR_ID MM_SERVING_OPERATOR_NAME
export SIM_OPERATOR_ID SIM_OPERATOR_NAME SIM_IMSI SIM_ICCID
roaming_json="$(sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["home_operator_id"] == "25506"; assert d["serving_operator_id"] == "26201"; assert d["registration_state"] == "roaming"; assert d["roaming"] is True; assert d["roaming_policy"] == "default-allow" and d["roaming_allowed"] is True' "$roaming_json" || fail 'roaming status is incomplete'

printf '%s\n' 'TEST an explicit roaming block prevents APN changes and candidate cycling'
printf '%s\n' 0 >"$STATE/allow_roaming"
printf '%s\n' 'blocked.before' >"$STATE/apn"
: >"$STATE/events"
if sh "$SCRIPT" apply >/dev/null 2>&1; then
	fail 'roaming-blocked apply unexpectedly succeeded'
else
	blocked_status=$?
fi
[ "$blocked_status" -eq 2 ] || fail "roaming block returned $blocked_status instead of 2"
[ "$(cat "$STATE/apn")" = 'blocked.before' ] || fail 'roaming block changed the APN'
[ "$(grep -F -c 'down wwan' "$STATE/events")" -eq 1 ] || fail 'roaming block did not stop the active interface exactly once'
[ "$(grep -F -c 'up wwan' "$STATE/events")" -eq 0 ] || fail 'roaming block restarted the interface or cycled profiles'
[ "$(cat "$CACHE/last-result-code")" = 'blocked-roaming-policy' ] || fail 'roaming block result was not classified'

printf '%s\n' 'TEST explicit policy commands edit only the canonical network option'
: >"$STATE/events"
sh "$SCRIPT" roaming-policy-set allow >/dev/null 2>&1
[ "$(cat "$STATE/allow_roaming")" = 1 ] || fail 'allow policy did not write network.wwan.allow_roaming=1'
[ ! -s "$STATE/events" ] || fail 'allow policy restarted an already working interface'
sh "$SCRIPT" roaming-policy-set default >/dev/null 2>&1
[ ! -e "$STATE/allow_roaming" ] || fail 'default policy did not remove network.wwan.allow_roaming'
sh "$SCRIPT" roaming-policy-set block >/dev/null 2>&1
[ "$(cat "$STATE/allow_roaming")" = 0 ] || fail 'block policy did not write network.wwan.allow_roaming=0'
grep -F -q 'down wwan' "$STATE/events" || fail 'blocking data while roaming did not stop the interface'
printf 'v2\t89380062300756308069\tinternet.telekom\tfixture-user\tfixture-pass\tpap chap\tipv4v6\n' \
	>"$PERSIST/active.tsv"
printf '%s\n' internet.telekom >"$STATE/apn"
printf '%s\n' fixture-user >"$STATE/username"
printf '%s\n' fixture-pass >"$STATE/password"
printf '%s\n' 'pap chap' >"$STATE/allowedauth"
printf '%s\n' ipv4v6 >"$STATE/iptype"
rm -f "$STATE/ifup-seen"
: >"$STATE/events"
UBUS_UP=0 UBUS_UP_AFTER_IFUP=1 sh "$SCRIPT" roaming-policy-set allow >/dev/null 2>&1
[ "$(cat "$STATE/events")" = 'up wwan' ] || \
	fail 'allowing roaming reapplied an already reconciled profile instead of waiting for netifd'
printf '%s\n' 0 >"$STATE/allow_roaming"
MMCLI_UNAVAILABLE=1 sh "$SCRIPT" roaming-policy-set allow >/dev/null 2>&1
[ "$(cat "$STATE/allow_roaming")" = 1 ] || fail 'policy could not be saved while no SIM was readable'
rm -f "$STATE/allow_roaming" "$STATE/ifup-seen" "$PERSIST/active.tsv"

printf '%s\n' 'TEST registration denial and registration timeout do not test APNs'
rm -f "$STATE/allow_roaming"
MM_REGISTRATION_STATE=denied
export MM_REGISTRATION_STATE
: >"$STATE/events"
if sh "$SCRIPT" apply >/dev/null 2>&1; then fail 'denied registration unexpectedly applied a profile'; else denied_status=$?; fi
[ "$denied_status" -eq 1 ] || fail 'denied registration returned the wrong status'
[ ! -s "$STATE/events" ] || fail 'denied registration cycled profiles'
MM_REGISTRATION_STATE=searching
TEST_REGISTRATION_WAIT_SECONDS=1
export MM_REGISTRATION_STATE TEST_REGISTRATION_WAIT_SECONDS
if sh "$SCRIPT" apply >/dev/null 2>&1; then fail 'searching registration unexpectedly applied a profile'; else pending_status=$?; fi
[ "$pending_status" -eq 3 ] || fail 'searching registration was not classified as retryable'
[ ! -s "$STATE/events" ] || fail 'searching registration cycled profiles'

printf '%s\n' 'TEST temporary ModemManager or SIM unavailability remains retryable'
if MMCLI_UNAVAILABLE=1 sh "$SCRIPT" reconcile >/dev/null 2>&1; then fail 'unavailable modem unexpectedly reconciled'; else unavailable_status=$?; fi
[ "$unavailable_status" -eq 3 ] || fail 'temporary modem unavailability was not classified as retryable'

MM_REGISTRATION_STATE=home
SIM_OPERATOR_ID=26201
SIM_OPERATOR_NAME='Kaufland Mobil'
SIM_IMSI=262014740651867
SIM_ICCID=89490200002186275443
unset MM_SERVING_OPERATOR_ID MM_SERVING_OPERATOR_NAME TEST_REGISTRATION_WAIT_SECONDS
export MM_REGISTRATION_STATE SIM_OPERATOR_ID SIM_OPERATOR_NAME SIM_IMSI SIM_ICCID
printf '%s\n' 'rollback.apn' >"$STATE/apn"

printf '%s\n' 'TEST a home-to-roaming transition stops profile cycling and restores the old APN'
printf '%s\n' 0 >"$STATE/allow_roaming"
printf '%s\n' 'transition.before' >"$STATE/apn"
rm -f "$STATE/ifup-seen" "$CACHE/89490200002186275443.tsv"
: >"$STATE/events"
MM_REGISTRATION_AFTER_IFUP=roaming
export MM_REGISTRATION_AFTER_IFUP
if sh "$SCRIPT" apply >/dev/null 2>&1; then fail 'home-to-roaming transition unexpectedly succeeded'; else transition_status=$?; fi
[ "$transition_status" -eq 2 ] || fail 'home-to-roaming transition was not classified as blocked'
[ "$(cat "$STATE/apn")" = 'transition.before' ] || fail 'home-to-roaming transition did not restore the prior APN'
[ "$(tail -n 1 "$STATE/events")" = 'down wwan' ] || fail 'home-to-roaming rollback brought the blocked interface back up'
unset MM_REGISTRATION_AFTER_IFUP
rm -f "$STATE/allow_roaming" "$STATE/ifup-seen"
printf '%s\n' 'rollback.apn' >"$STATE/apn"

printf '%s\n' 'TEST background action reports busy and rejects an overlapping start'
rm -rf "$TEST_ACTION_STATE" "$TEST_ACTION_STATE.start-lock"
rm -f "$STATE/action-release"
BLOCK_ACTION=1 APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" \
	APN_AUTOCONFIG_ACTION_COMMAND="$MOCKBIN/apn-autoconfig-command" \
	sh "$SCRIPT" action-start reconcile >"$STATE/action-start.json"
/bin/sleep 1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["accepted"] is True' "$STATE/action-start.json" || fail 'first background action was not accepted'
busy_json="$(APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["busy"] is True and d["action"] == "reconcile"' "$busy_json" || fail 'running action not reported busy'
second_json="$(APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" sh "$SCRIPT" action-start modem-reset)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is False and d["busy"] is True' "$second_json" || fail 'overlapping background action was not rejected'
touch "$STATE/action-release"
action_wait=10
while [ "$action_wait" -gt 0 ]; do
	action_json="$(sh "$SCRIPT" action-status)"
	action_busy="$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["busy"]).lower())' "$action_json")"
	[ "$action_busy" = false ] && break
	/bin/sleep 1
	action_wait=$((action_wait - 1))
done
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "success" and d["busy"] is False' "$action_json" || fail 'background action did not reach success'

printf '%s\n' 'TEST a roaming policy block reaches a terminal blocked action state'
rm -rf "$TEST_ACTION_STATE"
ACTION_EXIT=2 APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" \
	APN_AUTOCONFIG_ACTION_COMMAND="$MOCKBIN/apn-autoconfig-command" \
	sh "$SCRIPT" action-start reconcile >"$STATE/action-blocked-start.json"
/bin/sleep 1
blocked_json="$(sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "blocked" and d["busy"] is False and d["exit_code"] == "2"' "$blocked_json" || fail 'policy block was reported as an action failure'

printf '%s\n' 'TEST temporary registration failure reaches a retryable action state'
rm -rf "$TEST_ACTION_STATE"
ACTION_EXIT=3 APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" \
	APN_AUTOCONFIG_ACTION_COMMAND="$MOCKBIN/apn-autoconfig-command" \
	sh "$SCRIPT" action-start reconcile >"$STATE/action-retryable-start.json"
/bin/sleep 1
retryable_json="$(sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "retryable" and d["busy"] is False and d["exit_code"] == "3"' "$retryable_json" || fail 'temporary registration failure was reported as permanent'

printf '%s\n' 'TEST roaming actions map to the narrow canonical policy command'
cat >"$MOCKBIN/apn-autoconfig-policy-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TEST_STATE/policy-action-args"
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-policy-command"
rm -rf "$TEST_ACTION_STATE"
rm -f "$STATE/policy-action-args"
APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" \
	APN_AUTOCONFIG_ACTION_COMMAND="$MOCKBIN/apn-autoconfig-policy-command" \
	sh "$SCRIPT" action-start roaming-allow >"$STATE/action-policy-start.json"
/bin/sleep 1
grep -F -x -q 'roaming-policy-set allow' "$STATE/policy-action-args" || fail 'roaming-allow action used the wrong command'
policy_action_json="$(sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "success" and d["busy"] is False' "$policy_action_json" || fail 'roaming policy action did not complete'

printf '%s\n' 'TEST database actions map to the narrow updater command'
cat >"$MOCKBIN/apn-autoconfig-database-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TEST_STATE/database-action-args"
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-database-command"
rm -rf "$TEST_ACTION_STATE"
rm -f "$STATE/database-action-args"
APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" \
	APN_AUTOCONFIG_DATABASE_COMMAND="$MOCKBIN/apn-autoconfig-database-command" \
	sh "$SCRIPT" action-start database-check >"$STATE/action-database-start.json"
/bin/sleep 1
grep -F -x -q 'check' "$STATE/database-action-args" || fail 'database-check action used the wrong command'
database_action_json="$(sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "success" and d["busy"] is False and d["action"] == "database-check"' "$database_action_json" || fail 'database check action did not complete'

printf '%s\n' 'TEST failed background action reaches a terminal state and releases GUI controls'
rm -rf "$TEST_ACTION_STATE"
ACTION_EXIT=7 APN_AUTOCONFIG_ACTION_WORKER="$BASE/files/usr/libexec/apn-autoconfig-action" \
	APN_AUTOCONFIG_ACTION_COMMAND="$MOCKBIN/apn-autoconfig-command" \
	sh "$SCRIPT" action-start reconcile >"$STATE/action-failed-start.json"
/bin/sleep 1
failed_json="$(sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"] == "failed" and d["busy"] is False and d["exit_code"] == "7"' "$failed_json" || fail 'failed action left GUI controls busy'

printf '%s\n' 'TEST an operation started outside the job API disables GUI actions'
rm -rf "$TEST_ACTION_STATE"
mkdir -p "$TEST_LOCK"
printf '%s\n' "$$" >"$TEST_LOCK/pid"
external_json="$(sh "$SCRIPT" action-status)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["busy"] is True and d["state"] == "external"' "$external_json" || fail 'external operation lock was not exposed'
if sh "$SCRIPT" reconcile >/dev/null 2>&1; then
	fail 'reconcile unexpectedly started while another operation held the lock'
else
	lock_status=$?
fi
[ "$lock_status" -eq 3 ] || fail 'live operation lock contention was not classified as retryable'
rm -rf "$TEST_LOCK"

printf '%s\n' 'TEST boot worker is inert while autostart is disabled'
rm -f "$STATE/boot-calls"
TEST_AUTOSTART=0
export TEST_AUTOSTART
sh "$BOOT_SCRIPT" >/dev/null 2>&1
[ ! -e "$STATE/boot-calls" ] || fail 'disabled boot worker invoked reconcile'

printf '%s\n' 'TEST boot worker retries a bounded failure and then succeeds'
TEST_AUTOSTART=1
TEST_BOOT_ATTEMPTS=3
BOOT_SUCCESS_AT=2
export TEST_AUTOSTART TEST_BOOT_ATTEMPTS BOOT_SUCCESS_AT
sh "$BOOT_SCRIPT" >/dev/null 2>&1
[ "$(cat "$STATE/boot-calls")" -eq 2 ] || fail 'boot worker did not stop after successful retry'

printf '%s\n' 'TEST boot worker fails after the configured attempt limit'
rm -f "$STATE/boot-calls"
TEST_BOOT_ATTEMPTS=2
BOOT_SUCCESS_AT=99
export TEST_BOOT_ATTEMPTS BOOT_SUCCESS_AT
if sh "$BOOT_SCRIPT" >/dev/null 2>&1; then
	fail 'boot worker unexpectedly succeeded after exhausted retries'
fi
[ "$(cat "$STATE/boot-calls")" -eq 2 ] || fail 'boot worker ignored the attempt limit'

printf '%s\n' 'TEST boot worker stops without retrying an intentional policy block'
rm -f "$STATE/boot-calls"
ACTION_EXIT=2
export ACTION_EXIT
sh "$BOOT_SCRIPT" >/dev/null 2>&1 || fail 'boot worker treated policy block as a service failure'
[ ! -e "$STATE/boot-calls" ] || fail 'blocked boot reconciliation was retried'
unset ACTION_EXIT

printf '%s\n' 'TEST hardware modem reset restores power and reconciles APN'
printf '%s\n' 'wrong.apn' >"$STATE/apn"
SIM_ICCID=89490200002186275443
CURL_SUCCESS_APN=internet.telekom
export SIM_ICCID CURL_SUCCESS_APN
: >"$STATE/events"
sh "$SCRIPT" modem-reset >/dev/null 2>&1
[ "$(cat "$TEST_GPIO")" = '0' ] || fail 'modem power was not restored after reset'
[ "$(cat "$STATE/apn")" = 'internet.telekom' ] || fail 'modem reset did not reconcile APN'
grep -F -q 'down wwan' "$STATE/events" || fail 'modem reset did not stop WWAN'
grep -F -q 'up wwan' "$STATE/events" || fail 'modem reset did not restore WWAN'

printf '%s\n' 'TEST failed modem return leaves power on and attempts WWAN recovery'
: >"$STATE/events"
if MMCLI_UNAVAILABLE=1 sh "$SCRIPT" modem-reset >/dev/null 2>&1; then
	fail 'modem reset unexpectedly succeeded while ModemManager was unavailable'
fi
[ "$(cat "$TEST_GPIO")" = '0' ] || fail 'failed modem reset left modem power off'
grep -F -q 'up wwan' "$STATE/events" || fail 'failed modem reset did not attempt WWAN recovery'

printf '%s\n' 'TEST button ignores press and queues modem reset only on release'
cat >"$MOCKBIN/apn-autoconfig-button-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_STATE/button-calls"
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-button-command"
rm -f "$STATE/button-calls"
TEST_BUTTON_ENABLED=0 BUTTON=BTN_0 ACTION=released \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
[ ! -e "$STATE/button-calls" ] || fail 'disabled button queued modem-reset'
TEST_BUTTON_ENABLED=1 BUTTON=BTN_0 ACTION=pressed \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
[ ! -e "$STATE/button-calls" ] || fail 'button press triggered the action before release'
TEST_BUTTON_ENABLED=1 BUTTON=BTN_0 ACTION=released \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
button_wait=10
while [ ! -e "$STATE/button-calls" ] && [ "$button_wait" -gt 0 ]; do
	/bin/sleep 1
	button_wait=$((button_wait - 1))
done
grep -F -x -q 'action-start modem-reset' "$STATE/button-calls" || \
	fail 'button release did not queue modem-reset through the job API'

printf '%s\n' 'All tests passed.'
