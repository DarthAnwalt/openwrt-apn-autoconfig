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
[ "${MMCLI_UNAVAILABLE:-0}" = "1" ] && exit 1
case "${1:-}" in
-L)
	printf '%s\n' "    /org/freedesktop/ModemManager1/Modem/${MM_MODEM_INDEX:-7} [Quectel] RM520N-GL"
	exit 0
	;;
-m)
	printf '%s\n' \
		"modem.generic.device : /sys/devices/mock-modem" \
		"modem.generic.physdev : /sys/devices/mock-modem" \
		"modem.generic.sim : /org/freedesktop/ModemManager1/SIM/${MM_SIM_INDEX:-9}"
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
[ "$count" -ge "${BOOT_SUCCESS_AT:-1}" ]
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

printf '%s\n' 'TEST detect is read-only and finds the specific candidate'
before="$(cat "$STATE/apn")"
detect_output="$(sh "$SCRIPT" detect 2>&1)"
assert_contains "$detect_output" 'Kaufland Mobil'
assert_contains "$detect_output" 'SIM index:       9'
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

printf '%s\n' 'TEST machine-readable status and detect output are valid JSON'
status_json="$(sh "$SCRIPT" status-json)"
detect_json="$(sh "$SCRIPT" detect-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["configured_apn"] == "rollback.apn"; assert d["interface_up"] is True' "$status_json" || fail 'invalid status JSON'
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["iccid"] == "89490200002186275443"; assert len(d["candidates"]) == 1; assert d["candidates"][0]["apn"] == "internet.telekom"' "$detect_json" || fail 'invalid detect JSON'

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

printf '%s\n' 'TEST button ignores press and invokes modem reset only on release'
cat >"$MOCKBIN/apn-autoconfig-button-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_STATE/button-calls"
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-button-command"
rm -f "$STATE/button-calls"
TEST_BUTTON_ENABLED=0 BUTTON=BTN_0 ACTION=released \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
[ ! -e "$STATE/button-calls" ] || fail 'disabled button invoked modem-reset'
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
grep -F -q 'modem-reset' "$STATE/button-calls" || fail 'button release did not invoke modem-reset'

printf '%s\n' 'All tests passed.'
