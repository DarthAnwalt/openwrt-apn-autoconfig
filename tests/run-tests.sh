#!/bin/sh
set -eu

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="${TMPDIR:-/tmp}/apn-autoconfig-test.$$"
TEST_ACTION_STATE="/tmp/apn-autoconfig-action-test.$$"
HARDWARE_MARKER="$TESTROOT/huasifei-wh3000-integration"
MOCKBIN="$TESTROOT/bin"
STATE="$TESTROOT/state"
DB="$TESTROOT/providers.tsv"
PERSIST="$TESTROOT/persist"
TARGET_PERSIST="$PERSIST/targets/network_wwan"
CACHE="$PERSIST/cache"
SCRIPT="$BASE/files/usr/sbin/apn-autoconfig"
BOOT_SCRIPT="$BASE/files/usr/libexec/apn-autoconfig-boot"
BUTTON_SCRIPT="$BASE/files/etc/hotplug.d/button/50-apn-autoconfig"
QUERY_SCRIPT="$BASE/files/usr/libexec/apn-autoconfig-query"
CONTROL_SCRIPT="$BASE/files/usr/libexec/apn-autoconfig-control"

cleanup() {
	rm -rf "$TESTROOT" "$TEST_ACTION_STATE" "$TEST_ACTION_STATE.start-lock"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$MOCKBIN" "$STATE" "$CACHE" "$PERSIST"
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
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
printf '%s\n' 'qmi.old' >"$STATE/qmi-apn"
printf '%s\n' 'qmi-user' >"$STATE/qmi-username"
printf '%s\n' 'qmi-pass' >"$STATE/qmi-password"
printf '%s\n' 'chap' >"$STATE/qmi-auth"
printf '%s\n' 'ip' >"$STATE/qmi-pdptype"

cat >"$MOCKBIN/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
case "$1:$2" in
show:network)
	if [ "${TEST_SINGLE_TARGET:-0}" = 1 ]; then
		printf '%s\n' \
			"network.wwan=interface" \
			"network.wwan.proto='modemmanager'" \
			"network.wwan.device='/sys/devices/mock-modem'"
	else
		printf '%s\n' \
			"network.wwan=interface" \
			"network.wwan.proto='modemmanager'" \
			"network.wwan.device='/sys/devices/mock-modem'" \
			"network.cellqmi=interface" \
			"network.cellqmi.proto='qmi'" \
			"network.cellmbim=interface" \
			"network.cellmbim.proto='mbim'"
	fi
	if [ "${TEST_STAGING_SECTION:-0}" = 1 ]; then
		printf '%s\n' "network.apnmodem1=interface" "network.apnmodem1.proto='qmi'"
	fi
	if [ "${TEST_SECOND_MM:-0}" = 1 ]; then
		printf '%s\n' "network.wwan2=interface" "network.wwan2.proto='modemmanager'"
	fi
;;
get:network.apnmodem1.proto) [ "${TEST_STAGING_SECTION:-0}" = 1 ] && printf '%s\n' qmi ;;
get:network.apnmodem1.device)
	[ "${TEST_STAGING_SECTION:-0}" = 1 ] && printf '%s\n' "${TEST_QMI_DEVICE:-/dev/cdc-wdm0}"
;;
get:network.apnmodem1.apn_autoconfig_owner)
	[ "${TEST_STAGING_SECTION:-0}" = 1 ] && printf '%s\n' apn-autoconfig-modem
;;
get:network.apnmodem1.disabled)
	[ "${TEST_STAGING_SECTION:-0}" = 1 ] && [ "${TEST_STAGING_PROMOTED:-0}" = 0 ] && printf '%s\n' 1
;;
get:apn-autoconfig.main.interface) printf '%s\n' "${TEST_INTERFACE:-wwan}" ;;
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
get:network.wwan.proto) printf '%s\n' modemmanager ;;
get:network.wwan2.proto) printf '%s\n' modemmanager ;;
get:network.cellqmi.proto) printf '%s\n' qmi ;;
get:network.cellqmi.device) [ "${TEST_QMI_USE_DEVPATH:-0}" = 1 ] || printf '%s\n' "${TEST_QMI_DEVICE:-/dev/cdc-wdm0}" ;;
get:network.cellqmi.devpath) [ "${TEST_QMI_USE_DEVPATH:-0}" = 1 ] && printf '%s\n' "$TEST_QMI_DEVPATH" ;;
get:network.cellqmi.apn) cat "$TEST_STATE/qmi-apn" ;;
get:network.cellqmi.username) cat "$TEST_STATE/qmi-username" ;;
get:network.cellqmi.password) cat "$TEST_STATE/qmi-password" ;;
get:network.cellqmi.auth) cat "$TEST_STATE/qmi-auth" ;;
get:network.cellqmi.pdptype) cat "$TEST_STATE/qmi-pdptype" ;;
get:network.cellqmi.allow_roaming) cat "$TEST_STATE/qmi-allow_roaming" ;;
get:network.cellmbim.proto) printf '%s\n' mbim ;;
get:network.wwan.apn) cat "$TEST_STATE/apn" ;;
get:network.wwan2.apn) cat "$TEST_STATE/apn-wwan2" ;;
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
		network.wwan2.apn=*) printf '%s\n' "${2#network.wwan2.apn=}" >"$TEST_STATE/apn-wwan2" ;;
		network.cellqmi.*=*)
			option="${2#network.cellqmi.}"
			value="${option#*=}"
			option="${option%%=*}"
			case "$option" in apn|username|password|auth|pdptype) printf '%s\n' "$value" >"$TEST_STATE/qmi-$option" ;; *) exit 1 ;; esac
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
delete:network.wwan2.apn) rm -f "$TEST_STATE/apn-wwan2" ;;
delete:network.cellqmi.apn) rm -f "$TEST_STATE/qmi-apn" ;;
delete:network.cellqmi.username) rm -f "$TEST_STATE/qmi-username" ;;
delete:network.cellqmi.password) rm -f "$TEST_STATE/qmi-password" ;;
delete:network.cellqmi.auth) rm -f "$TEST_STATE/qmi-auth" ;;
delete:network.cellqmi.pdptype) rm -f "$TEST_STATE/qmi-pdptype" ;;
commit:network) : ;;
*) exit 1 ;;
esac
EOF

cat >"$MOCKBIN/mmcli" <<'EOF'
#!/bin/sh
[ "${MMCLI_UNAVAILABLE:-0}" = "1" ] && exit 1
[ "${MMCLI_HANG:-0}" != 1 ] || {
	printf '%s\n' "$$" >"$TEST_STATE/mmcli-hang-pid"
	exec /bin/sleep 30
}
case "${1:-}" in
-L)
	printf '%s\n' "    /org/freedesktop/ModemManager1/Modem/${MM_MODEM_INDEX:-7} [Quectel] RM520N-GL"
	exit 0
	;;
-m)
	if [ "${MM_DELAY_AFTER_COORDINATOR:-0}" = 1 ] && [ -e "$TEST_STATE/coordinator-reset-complete" ]; then
		count="$(cat "$TEST_STATE/coordinator-mm-count" 2>/dev/null || printf '%s' 0)"
		count=$((count + 1))
		printf '%s\n' "$count" >"$TEST_STATE/coordinator-mm-count"
		if [ "$count" -lt 3 ]; then
			exit 1
		fi
		: >"$TEST_STATE/coordinator-sim-ready"
	fi
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
suffix=""
[ -z "${UBUS_L3_DEVICE:-}" ] || suffix=", \"l3_device\": \"$UBUS_L3_DEVICE\""
case "${2:-}" in
	network.interface.*_4)
		[ "${QMI_DATA_UNAVAILABLE:-0}" = 1 ] || suffix="${suffix}, \"ipv4-address\": [{ \"address\": \"192.0.2.2\" }]"
		[ "${QMI_TRACE_RESET_ORDER:-0}" != 1 ] || printf '%s\n' data >>"$TEST_STATE/qmi-reset-order"
	;;
esac
if [ "${QMI_DUALSTACK_REJECT:-0}" = 1 ] && [ "$(cat "$TEST_STATE/qmi-pdptype" 2>/dev/null || :)" = ipv4v6 ]; then
	printf '{ "up": false%s }\n' "$suffix"
elif [ "${UBUS_UP_AFTER_IFUP:-0}" = 1 ] && [ -e "$TEST_STATE/ifup-seen" ]; then
	printf '{ "up": true%s }\n' "$suffix"
elif [ "${UBUS_UP:-1}" = 1 ]; then
	printf '{ "up": true%s }\n' "$suffix"
else
	printf '{ "up": false%s }\n' "$suffix"
fi
EOF

cat >"$MOCKBIN/ifdown" <<'EOF'
#!/bin/sh
printf 'down %s\n' "$1" >>"$TEST_STATE/events"
EOF

cat >"$MOCKBIN/ifup" <<'EOF'
#!/bin/sh
printf 'up %s\n' "$1" >>"$TEST_STATE/events"
[ "${QMI_TRACE_RESET_ORDER:-0}" != 1 ] || printf '%s\n' up >>"$TEST_STATE/qmi-reset-order"
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
previous=""
for argument in "$@"; do
	[ "$previous" = --interface ] && printf '%s\n' "$argument" >"$TEST_STATE/curl-device"
	previous="$argument"
done
current="$(cat "$TEST_STATE/apn" 2>/dev/null || :)"
[ "${TEST_INTERFACE:-wwan}" != cellqmi ] || current="$(cat "$TEST_STATE/qmi-apn" 2>/dev/null || :)"
[ "$current" = "${CURL_SUCCESS_APN:-internet.telekom}" ]
EOF

cat >"$MOCKBIN/logger" <<'EOF'
#!/bin/sh
[ -z "${TEST_LOGGER_CALLS:-}" ] || printf '%s\n' "$*" >>"$TEST_LOGGER_CALLS"
exit 0
EOF

cat >"$MOCKBIN/sleep" <<'EOF'
#!/bin/sh
[ "${BLOCK_QMI_SETTLE:-0}" != 1 ] || [ "${1:-}" != 6 ] || [ -e "$TEST_STATE/qmi-settle-seen" ] || {
	: >"$TEST_STATE/qmi-settle-seen"
	printf '%s\n' "$$" >"$TEST_STATE/qmi-settle-pid"
	exec /bin/sleep 30
}
exit 0
EOF

cat >"$MOCKBIN/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF

cat >"$MOCKBIN/jsonfilter" <<'EOF'
#!/bin/sh
document=
expression=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-s) document="$2"; shift 2 ;;
		-e) expression="$2"; shift 2 ;;
		*) exit 2 ;;
	esac
done
python3 -c '
import json, sys
value = json.loads(sys.argv[1])
path = sys.argv[2]
if path.startswith("@[*]."):
    key = path[5:]
    for item in value:
        if key in item and item[key] is not None:
            print(item[key])
    raise SystemExit(0)
if not path.startswith("@."):
    raise SystemExit(1)
for part in path[2:].split("."):
    if part.endswith("[0]"):
        value = value[part[:-3]][0]
    else:
        value = value[part]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
' "$document" "$expression" 2>/dev/null
EOF

cat >"$MOCKBIN/uqmi" <<'EOF'
#!/bin/sh
operation=
for argument in "$@"; do
	case "$argument" in
		--get-iccid) operation=get-iccid ;;
		--get-imsi) operation=get-imsi ;;
		--get-serving-system) operation=get-serving-system ;;
		--get-signal-info) operation=get-signal-info ;;
	esac
done
[ -n "$operation" ] || exit 2
printf '%s\n' "$*" >>"$TEST_STATE/uqmi-calls"
if [ "${QMI_TRACE_RESET_ORDER:-0}" = 1 ] && [ "$operation" = get-iccid ]; then
	printf '%s\n' identity >>"$TEST_STATE/qmi-reset-order"
fi
[ "${QMI_FAIL_OPERATION:-}" != "$operation" ] || exit 1
if [ "$operation" = get-iccid ] && [ -n "${QMI_MALFORMED_ICCID:-}" ]; then
	printf '"%s"\n' "$QMI_MALFORMED_ICCID"
	exit 0
fi
cat "$QMI_FIXTURE_DIR/$operation.json"
EOF

cat >"$MOCKBIN/sms_tool" <<'EOF'
#!/bin/sh
device=
command=
while [ "$#" -gt 0 ]; do
	case "$1" in
		-d) device="$2"; shift 2 ;;
		at) command="$2"; shift 2 ;;
		*) exit 2 ;;
	esac
done
printf '%s\t%s\n' "$device" "$command" >>"$TEST_STATE/sms-tool-calls"
if [ "$device" = "${SMS_TOOL_BLOCK_DEVICE:-}" ]; then
	trap 'exit 1' TERM
	/bin/sleep 10
	exit 1
fi
[ "$device" = "${SMS_TOOL_EXPECT_DEVICE:-/dev/ttyUSB2}" ] || exit 1
[ "${SMS_TOOL_HANG:-0}" != 1 ] || exec /bin/sleep 10
if [ "${SMS_TOOL_REQUIRE_SERIAL:-0}" = 1 ]; then
	if ! mkdir "$TEST_STATE/sms-tool-active" 2>/dev/null; then
		printf '%s\n' collision >>"$TEST_STATE/sms-tool-collisions"
		exit 1
	fi
	trap 'rmdir "$TEST_STATE/sms-tool-active"' EXIT HUP INT TERM
	/bin/sleep 0.2
fi
case "$command" in
	AT+CCID)
		[ "${SMS_TOOL_QCCID_ONLY:-0}" != 1 ] || exit 1
		if [ -n "${SMS_TOOL_MALFORMED_ICCID:-}" ]; then
			printf '\r\n+CCID: %s\r\n\r\n' "$SMS_TOOL_MALFORMED_ICCID"
			exit 0
		fi
		printf '\r\n+CCID: 89490200002186275443\r\n\r\n'
	;;
	AT+QCCID)
		[ -z "${SMS_TOOL_MALFORMED_ICCID:-}" ] || exit 1
		printf '\r\n+QCCID: 89490200002186275443\r\n\r\n'
	;;
	AT+CIMI) printf '\r\n262014740651867\r\n\r\n' ;;
	*) exit 2 ;;
esac
EOF

cat >"$MOCKBIN/readlink" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = -f ] || exit 2
python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2"
EOF

chmod 0755 "$MOCKBIN"/*
export PATH="$MOCKBIN:/usr/bin:/bin"
export TEST_DB="$DB" TEST_CACHE="$CACHE" TEST_STATE="$STATE" TEST_LOCK="$TESTROOT/lock" TEST_PERSIST="$PERSIST"
export TEST_GPIO="$TESTROOT/sys/class/gpio/modem_power/value"
export APN_AUTOCONFIG_SYSFS_ROOT="$TESTROOT/sys"
export APN_AUTOCONFIG_QMI_ADAPTER="$BASE/files/usr/libexec/apn-autoconfig-qmi"
export APN_AUTOCONFIG_QMI_IDENTITY_LOCK_ROOT="$TESTROOT/qmi-identity-lock"
export APN_AUTOCONFIG_QMI_AT_CACHE_DIR="$TESTROOT/qmi-at-cache"
export QMI_FIXTURE_DIR="$BASE/tests/fixtures/qmi/home"
export APN_AUTOCONFIG_HARDWARE_INTEGRATION="$HARDWARE_MARKER"

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

file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

printf '%s\n' 'TEST target inventory reports exact backend capabilities'
targets_json="$(sh "$SCRIPT" targets-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); t={x["id"]:x for x in d["targets"]}; assert d["version"] == "v2"; assert t["network:wwan"]["backend"] == "modemmanager"; assert t["network:wwan"]["capabilities"]["profile_apply"] is True; assert t["network:wwan"]["implementation_state"] == "stable" and t["network:wwan"]["hardware_validated"] is True; assert t["network:cellqmi"]["backend"] == "qmi" and all(t["network:cellqmi"]["capabilities"].values()); assert t["network:cellqmi"]["implementation_state"] == "stable" and t["network:cellqmi"]["validation_state"] == "hardware" and t["network:cellqmi"]["hardware_validated"] is True; assert t["network:cellqmi"]["unavailable_reason"] == ""; assert t["network:cellmbim"]["backend"] == "mbim" and t["network:cellmbim"]["unavailable_reason"] == "backend-not-implemented"' "$targets_json" || fail 'invalid target inventory contract'

qmi_unavailable_json="$(APN_AUTOCONFIG_QMI_ADAPTER="$TESTROOT/missing-qmi-adapter" sh "$SCRIPT" targets-json)"
python3 -c 'import json,sys; t={x["id"]:x for x in json.loads(sys.argv[1])["targets"]}; q=t["network:cellqmi"]; assert q["capabilities"]["identity"] is False; assert q["implementation_state"] == "stable"; assert q["validation_state"] == "hardware"; assert q["hardware_validated"] is True; assert q["unavailable_reason"] == "adapter-unavailable"' "$qmi_unavailable_json" || fail 'missing QMI adapter was reported as available'
qmi_command_unavailable_json="$(APN_AUTOCONFIG_UQMI="$TESTROOT/missing-uqmi" sh "$SCRIPT" targets-json)"
python3 -c 'import json,sys; t={x["id"]:x for x in json.loads(sys.argv[1])["targets"]}; q=t["network:cellqmi"]; assert q["capabilities"]["identity"] is False and q["unavailable_reason"] == "backend-command-unavailable"' "$qmi_command_unavailable_json" || fail 'missing uqmi command was reported as available'
qmi_at_command_unavailable_json="$(APN_AUTOCONFIG_SMS_TOOL="$TESTROOT/missing-sms-tool" sh "$SCRIPT" targets-json)"
python3 -c 'import json,sys; t={x["id"]:x for x in json.loads(sys.argv[1])["targets"]}; q=t["network:cellqmi"]; assert q["capabilities"]["identity"] is False and q["unavailable_reason"] == "backend-command-unavailable"' "$qmi_at_command_unavailable_json" || fail 'missing mandatory sms-tool command was reported as available'
qmi_without_external_timeout_json="$(APN_AUTOCONFIG_TIMEOUT="$TESTROOT/missing-timeout" TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["target_backend"] == "qmi" and d["target_capabilities"]["identity"] is True; assert d["registration_state"] == "home"' "$qmi_without_external_timeout_json" || fail 'QMI identity required an undeclared external timeout command'

printf '%s\n' 'TEST QMI AT fallback remains bounded without an external timeout command'
qmi_at_timeout_start="$(date +%s)"
if QMI_FAIL_OPERATION=get-iccid SMS_TOOL_HANG=1 \
	APN_AUTOCONFIG_TIMEOUT="$TESTROOT/missing-timeout" \
	APN_AUTOCONFIG_SLEEP=/bin/sleep APN_AUTOCONFIG_AT_TIMEOUT_SECONDS=1 \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'hung QMI AT fallback unexpectedly returned identity'
else
	[ "$?" -eq 3 ] || fail 'hung QMI AT fallback was not classified as retryable'
fi
qmi_at_timeout_elapsed=$(( $(date +%s) - qmi_at_timeout_start ))
[ "$qmi_at_timeout_elapsed" -le 5 ] || fail 'QMI AT fallback exceeded its bounded timeout'

printf '%s\n' 'TEST QMI identity falls back to read-only AT ports on the same USB modem'
qmi_at_usb="$TESTROOT/sys/devices/platform/mock-usb/2-1"
mkdir -p \
	"$qmi_at_usb/2-1:1.1/ttyUSB0" \
	"$qmi_at_usb/2-1:1.2/ttyUSB2" \
	"$qmi_at_usb/2-1:1.4/usbmisc" \
	"$TESTROOT/sys/devices/platform/mock-usb/3-1/3-1:1.2/ttyUSB9" \
	"$TESTROOT/outside-sysfs/ttyUSB8" \
	"$TESTROOT/sys/class/usbmisc/cdc-wdm0" \
	"$TESTROOT/sys/class/tty/ttyUSB0" \
	"$TESTROOT/sys/class/tty/ttyUSB2" \
	"$TESTROOT/sys/class/tty/ttyUSB8" \
	"$TESTROOT/sys/class/tty/ttyUSB9"
: >"$qmi_at_usb/2-1:1.4/usbmisc/cdc-wdm0"
ln -s "$qmi_at_usb/2-1:1.4" "$TESTROOT/sys/class/usbmisc/cdc-wdm0/device"
ln -s "$qmi_at_usb/2-1:1.1/ttyUSB0" "$TESTROOT/sys/class/tty/ttyUSB0/device"
ln -s "$qmi_at_usb/2-1:1.2/ttyUSB2" "$TESTROOT/sys/class/tty/ttyUSB2/device"
ln -s "$TESTROOT/outside-sysfs/ttyUSB8" "$TESTROOT/sys/class/tty/ttyUSB8/device"
ln -s "$TESTROOT/sys/devices/platform/mock-usb/3-1/3-1:1.2/ttyUSB9" \
	"$TESTROOT/sys/class/tty/ttyUSB9/device"
: >"$STATE/sms-tool-calls"
qmi_at_json="$(QMI_FAIL_OPERATION=get-iccid SMS_TOOL_QCCID_ONLY=1 \
	SMS_TOOL_BLOCK_DEVICE=/dev/ttyUSB0 \
	APN_AUTOCONFIG_TIMEOUT="$TESTROOT/missing-timeout" \
	APN_AUTOCONFIG_SLEEP=/bin/sleep APN_AUTOCONFIG_AT_TIMEOUT_SECONDS=1 \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["iccid"] == "89490200002186275443"; assert d["imsi"] == "262014740651867"; assert d["registration_state"] == "home"' "$qmi_at_json" || fail 'QMI AT identity fallback returned invalid data'
grep -F -x -q "$(printf '/dev/ttyUSB2\tAT+CCID')" "$STATE/sms-tool-calls" || fail 'standard ICCID command was not attempted first'
grep -F -x -q "$(printf '/dev/ttyUSB2\tAT+QCCID')" "$STATE/sms-tool-calls" || fail 'Quectel ICCID fallback was not attempted'
grep -F -x -q "$(printf '/dev/ttyUSB2\tAT+CIMI')" "$STATE/sms-tool-calls" || fail 'standard IMSI command was not attempted'
[ "$(grep -F -c '/dev/ttyUSB0' "$STATE/sms-tool-calls")" -eq 1 ] || fail 'timed-out AT port received a redundant vendor command'
if grep -E -q '/dev/ttyUSB(8|9)' "$STATE/sms-tool-calls"; then
	fail 'QMI identity probed an AT port belonging to another USB modem'
fi
[ "$(cat "$TESTROOT/qmi-at-cache/cdc-wdm0.at-device")" = /dev/ttyUSB2 ] || fail 'successful QMI AT port was not cached'
: >"$STATE/sms-tool-calls"
QMI_FAIL_OPERATION=get-iccid TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >/dev/null
if grep -F -q '/dev/ttyUSB0' "$STATE/sms-tool-calls"; then
	fail 'cached QMI AT identity retried an earlier non-responsive port'
fi

printf '%s\n' 'TEST concurrent QMI identity calls serialize access to the AT port'
rm -f "$STATE/sms-tool-collisions"
QMI_FAIL_OPERATION=get-iccid SMS_TOOL_REQUIRE_SERIAL=1 APN_AUTOCONFIG_SLEEP=/bin/sleep \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >"$STATE/qmi-concurrent-1.json" &
qmi_first_pid=$!
/bin/sleep 0.05
QMI_FAIL_OPERATION=get-iccid SMS_TOOL_REQUIRE_SERIAL=1 APN_AUTOCONFIG_SLEEP=/bin/sleep \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >"$STATE/qmi-concurrent-2.json" &
qmi_second_pid=$!
wait "$qmi_first_pid" || fail 'first concurrent QMI identity call failed'
wait "$qmi_second_pid" || fail 'second concurrent QMI identity call failed'
[ ! -e "$STATE/sms-tool-collisions" ] || fail 'concurrent QMI identity calls overlapped on the AT port'
[ ! -d "$TESTROOT/qmi-identity-lock.cdc-wdm0" ] || fail 'QMI identity lock remained after successful calls'

printf '%s\n' 'TEST QMI identity is read-only and matches candidates from fixture output'
: >"$STATE/events"
: >"$STATE/uqmi-calls"
before="$(cat "$STATE/apn")"
qmi_json="$(TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["target_backend"] == "qmi"; assert all(d["target_capabilities"].values()); assert d["target_implementation_state"] == "stable" and d["target_validation_state"] == "hardware" and d["target_hardware_validated"] is True; assert d["iccid"] == "89490200002186275443"; assert d["imsi"] == "262014740651867"; assert d["home_operator_id"] == ""; assert d["serving_operator_id"] == "26201"; assert d["registration_state"] == "home"; assert d["roaming"] is False; assert d["candidates"][0]["apn"] == "internet.telekom"' "$qmi_json" || fail 'QMI identity contract returned invalid data'
[ "$(cat "$STATE/apn")" = "$before" ] || fail 'QMI identity changed the ModemManager APN'
[ ! -s "$STATE/events" ] || fail 'QMI identity cycled a network interface'
[ "$(wc -l <"$STATE/uqmi-calls" | tr -d ' ')" -eq 4 ] || fail 'QMI identity issued an unexpected command count'
if grep -E -- '--(start-network|modify-profile|set-|stop-network|verify|power)' "$STATE/uqmi-calls" >/dev/null; then
	fail 'QMI identity issued a mutating uqmi command'
fi
qmi_status_json="$(TEST_INTERFACE=cellqmi sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["signal_quality"] == "43"' \
	"$qmi_status_json" || fail 'QMI status did not normalize the best RSRP signal quality'

printf '%s\n' 'TEST QMI roaming keeps home identity separate from serving PLMN'
QMI_FIXTURE_DIR="$BASE/tests/fixtures/qmi/roaming"
export QMI_FIXTURE_DIR
printf '%s\n' 0 >"$STATE/qmi-allow_roaming"
qmi_roaming_json="$(TEST_INTERFACE=cellqmi sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["imsi"].startswith("25506"); assert d["home_operator_id"] == ""; assert d["serving_operator_id"] == "26202"; assert d["serving_operator_name"] == "Vodafone.de"; assert d["registration_state"] == "roaming" and d["roaming"] is True; assert d["roaming_policy"] == "unsupported" and d["roaming_allowed"] is True; assert d["signal_quality"] == "63"' "$qmi_roaming_json" || fail 'QMI roaming confused home and serving networks or inherited an unsupported policy'
rm -f "$STATE/qmi-allow_roaming"
QMI_FIXTURE_DIR="$BASE/tests/fixtures/qmi/home"
export QMI_FIXTURE_DIR

printf '%s\n' 'TEST QMI resolves one stable OpenWrt devpath and rejects ambiguity'
qmi_devpath="$TESTROOT/sys/devices/platform/mock-usb/1-2"
mkdir -p "$qmi_devpath/1-2:1.4/usbmisc"
: >"$qmi_devpath/1-2:1.4/usbmisc/cdc-wdm7"
: >"$STATE/uqmi-calls"
TEST_QMI_USE_DEVPATH=1 TEST_QMI_DEVPATH="$qmi_devpath" TEST_INTERFACE=cellqmi \
	sh "$SCRIPT" detect-json >/dev/null
grep -F -q -- '-d /dev/cdc-wdm7 ' "$STATE/uqmi-calls" || fail 'QMI devpath resolved the wrong control device'
outside_devpath="$TESTROOT/outside-qmi-devpath"
mkdir -p "$outside_devpath/usbmisc"
: >"$outside_devpath/usbmisc/cdc-wdm9"
ln -s "$outside_devpath" "$TESTROOT/sys/devices/qmi-devpath-escape"
if TEST_QMI_USE_DEVPATH=1 TEST_QMI_DEVPATH="$TESTROOT/sys/devices/qmi-devpath-escape" \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'QMI devpath symlink escaping sysfs was accepted'
fi
: >"$qmi_devpath/1-2:1.4/usbmisc/cdc-wdm8"
if TEST_QMI_USE_DEVPATH=1 TEST_QMI_DEVPATH="$qmi_devpath" TEST_INTERFACE=cellqmi \
	sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'ambiguous QMI devpath was accepted'
else
	[ "$?" -eq 4 ] || fail 'ambiguous QMI devpath did not use the target-contract exit code'
fi

printf '%s\n' 'TEST QMI timeout, malformed identity and unsafe devices fail closed'
if QMI_FAIL_OPERATION=get-iccid SMS_TOOL_EXPECT_DEVICE=/dev/ttyUSB99 \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'QMI timeout unexpectedly returned identity'
else
	[ "$?" -eq 3 ] || fail 'QMI timeout was not classified as retryable'
fi
if QMI_MALFORMED_ICCID='89;touch/tmp/pwn' TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'malformed QMI ICCID was accepted'
fi
rm -f "$TESTROOT/qmi-device-injection"
if TEST_QMI_DEVICE="/dev/cdc-wdm0;$TESTROOT/qmi-device-injection" TEST_INTERFACE=cellqmi \
	sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'unsafe QMI device path was accepted'
else
	[ "$?" -eq 4 ] || fail 'unsafe QMI device path did not use the target-contract exit code'
fi
[ ! -e "$TESTROOT/qmi-device-injection" ] || fail 'QMI device path executed shell content'
rm -f "$TESTROOT/qmi-at-injection"
if QMI_FAIL_OPERATION=get-iccid SMS_TOOL_MALFORMED_ICCID="89;touch$TESTROOT/qmi-at-injection" \
	TEST_INTERFACE=cellqmi sh "$SCRIPT" detect-json >/dev/null 2>&1; then
	fail 'malformed AT ICCID was accepted'
else
	[ "$?" -eq 3 ] || fail 'malformed AT ICCID did not fail closed as retryable identity'
fi
[ ! -e "$TESTROOT/qmi-at-injection" ] || fail 'AT modem output executed shell content'

printf '%s\n' 'TEST narrow integration wrappers preserve and validate target IDs'
cat >"$MOCKBIN/apn-autoconfig-wrapper-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$TEST_STATE/wrapper-args"
printf '{}\n'
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-wrapper-command"
APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-wrapper-command" \
	sh "$QUERY_SCRIPT" status network:wwan >/dev/null
[ "$(cat "$STATE/wrapper-args")" = 'status-json --target network:wwan' ] || fail 'query wrapper lost its target'
APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-wrapper-command" \
	sh "$CONTROL_SCRIPT" reconcile network:wwan >/dev/null
[ "$(cat "$STATE/wrapper-args")" = 'action-start reconcile --target network:wwan' ] || fail 'control wrapper lost its target'
if APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-wrapper-command" \
	sh "$CONTROL_SCRIPT" reconcile 'network:../../tmp/x' >/dev/null 2>&1; then
	fail 'control wrapper accepted an unsafe target'
fi
if APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-wrapper-command" \
	sh "$QUERY_SCRIPT" targets network:wwan >/dev/null 2>&1; then
	fail 'target inventory wrapper accepted a meaningless target argument'
fi

printf '%s\n' 'TEST unsupported backends fail before any profile or network mutation'
: >"$STATE/events"
before="$(cat "$STATE/apn")"
if unsupported_target_output="$(sh "$SCRIPT" apply --target network:cellmbim 2>&1)"; then
	fail 'MBIM target was allowed to apply a profile'
else
	unsupported_target_status=$?
fi
[ "$unsupported_target_status" -eq 4 ] || fail "unsupported target returned $unsupported_target_status instead of 4"
assert_contains "$unsupported_target_output" 'does not implement profile-apply'
[ "$(cat "$STATE/apn")" = "$before" ] || fail 'unsupported target changed APN'
[ ! -s "$STATE/events" ] || fail 'unsupported target cycled a network interface'
[ ! -e "$PERSIST/targets/network_cellmbim" ] || fail 'unsupported target created persistent state'

printf '%s\n' 'TEST unsafe and ambiguous target selection fails closed'
if sh "$SCRIPT" status-json --target 'network:../../tmp/x' >/dev/null 2>&1; then
	fail 'unsafe target ID was accepted'
else
	[ "$?" -eq 4 ] || fail 'unsafe target ID did not use the target-contract exit code'
fi
: >"$STATE/events"
if TEST_INTERFACE=auto sh "$SCRIPT" apply >/dev/null 2>&1; then
	fail 'ambiguous automatic target selection was accepted'
else
	[ "$?" -eq 4 ] || fail 'ambiguous target did not use the target-contract exit code'
fi
[ ! -s "$STATE/events" ] || fail 'ambiguous selection changed network state'

printf '%s\n' 'TEST QMI refuses legacy baselines that have no backend identity'
mkdir -p "$PERSIST/targets/network_cellqmi"
printf 'v2\tcellqmi\noption\tapn\t1\tlegacy.mm.apn\n' \
	>"$PERSIST/targets/network_cellqmi/baseline.tsv"
: >"$STATE/events"
if TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1; then
	fail 'QMI reset accepted a backend-less legacy baseline'
fi
[ "$(cat "$STATE/qmi-apn")" = qmi.old ] || fail 'legacy baseline changed the QMI APN'
[ ! -s "$STATE/events" ] || fail 'legacy baseline cycled the QMI interface'
rm -f "$PERSIST/targets/network_cellqmi/baseline.tsv"
rmdir "$PERSIST/targets/network_cellqmi"

printf '%s\n' 'TEST QMI applies the netifd profile and reset restores every owned option'
: >"$STATE/events"
mkdir -p "$CACHE"
printf 'v2\tinternet.telekom\tQMI cached fixture\t2026-01-01T00:00:00Z\tfixture-user\tfixture-pass\tpap-or-chap\tipv4v6\n' \
	>"$CACHE/89490200002186275443.tsv"
TEST_INTERFACE=cellqmi sh "$SCRIPT" apply >/dev/null 2>&1
[ "$(cat "$STATE/qmi-apn")" = internet.telekom ] || fail 'QMI apply did not set APN'
[ "$(cat "$STATE/qmi-username")" = fixture-user ] || fail 'QMI apply did not set username'
[ "$(cat "$STATE/qmi-password")" = fixture-pass ] || fail 'QMI apply did not set password'
[ "$(cat "$STATE/qmi-auth")" = both ] || fail 'QMI apply did not map pap-or-chap to uqmi both'
[ "$(cat "$STATE/qmi-pdptype")" = ipv4v6 ] || fail 'QMI apply did not keep a working dual-stack profile'
grep -F -q "$(printf 'option\tauth\t1\tchap')" "$PERSIST/targets/network_cellqmi/baseline.tsv" || \
	fail 'QMI baseline did not use the backend auth option'
grep -F -q "$(printf 'option\tpdptype\t1\tip')" "$PERSIST/targets/network_cellqmi/baseline.tsv" || \
	fail 'QMI baseline did not use the backend PDP option'
: >"$STATE/events"
TEST_INTERFACE=cellqmi sh "$SCRIPT" reconcile >/dev/null 2>&1
[ ! -s "$STATE/events" ] || fail 'QMI reconcile cycled an already verified profile'
cp "$PERSIST/targets/network_cellqmi/baseline.tsv" "$STATE/qmi-baseline.valid"
printf 'option\tallowedauth\t1\tpap chap\n' >>"$PERSIST/targets/network_cellqmi/baseline.tsv"
: >"$STATE/events"
if TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1; then
	fail 'QMI reset accepted a ModemManager-only baseline option'
fi
[ "$(cat "$STATE/qmi-apn")" = internet.telekom ] || fail 'invalid QMI baseline partially changed the profile'
[ ! -s "$STATE/events" ] || fail 'invalid QMI baseline cycled the interface'
cp "$STATE/qmi-baseline.valid" "$PERSIST/targets/network_cellqmi/baseline.tsv"
TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1
[ "$(cat "$STATE/qmi-apn")" = qmi.old ] || fail 'QMI reset did not restore APN'
[ "$(cat "$STATE/qmi-username")" = qmi-user ] || fail 'QMI reset did not restore username'
[ "$(cat "$STATE/qmi-password")" = qmi-pass ] || fail 'QMI reset did not restore password'
[ "$(cat "$STATE/qmi-auth")" = chap ] || fail 'QMI reset did not restore auth'
[ "$(cat "$STATE/qmi-pdptype")" = ip ] || fail 'QMI reset did not restore PDP type'

printf '%s\n' 'TEST QMI retries a rejected dual-stack bearer once with IPv4'
: >"$STATE/events"
mkdir -p "$CACHE"
printf 'v2\tinternet.telekom\tQMI dual-stack fixture\t2026-01-01T00:00:00Z\t-\t-\t-\tipv4v6\n' \
	>"$CACHE/89490200002186275443.tsv"
QMI_DUALSTACK_REJECT=1 TEST_INTERFACE=cellqmi sh "$SCRIPT" apply >/dev/null 2>&1
[ "$(cat "$STATE/qmi-pdptype")" = ip ] || fail 'QMI dual-stack fallback did not keep canonical IPv4 pdptype'
[ "$(awk -F '\t' 'NR == 1 { print $8 }' "$CACHE/89490200002186275443.tsv")" = ipv4 ] || \
	fail 'QMI dual-stack fallback did not cache the effective IP family'
[ "$(grep -F -c 'up cellqmi' "$STATE/events")" -eq 2 ] || fail 'QMI fallback did not make exactly two bearer attempts'
TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1

printf '%s\n' 'TEST failed QMI apply rolls back exactly and rejects ModemManager-only policy control'
CURL_SUCCESS_APN=never.matches
export CURL_SUCCESS_APN
if TEST_INTERFACE=cellqmi sh "$SCRIPT" apply >/dev/null 2>&1; then
	fail 'failed QMI candidates unexpectedly succeeded'
fi
[ "$(cat "$STATE/qmi-apn")" = qmi.old ] || fail 'failed QMI apply did not restore APN'
[ "$(cat "$STATE/qmi-username")" = qmi-user ] || fail 'failed QMI apply did not restore username'
[ "$(cat "$STATE/qmi-password")" = qmi-pass ] || fail 'failed QMI apply did not restore password'
[ "$(cat "$STATE/qmi-auth")" = chap ] || fail 'failed QMI apply did not restore auth'
[ "$(cat "$STATE/qmi-pdptype")" = ip ] || fail 'failed QMI apply did not restore PDP type'
if TEST_INTERFACE=cellqmi sh "$SCRIPT" roaming-policy-set block >/dev/null 2>&1; then
	fail 'QMI target accepted ModemManager-only roaming policy control'
else
	[ "$?" -eq 4 ] || fail 'unsupported QMI roaming policy returned the wrong status'
fi
TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1
CURL_SUCCESS_APN=internet.telekom
export CURL_SUCCESS_APN

printf '%s\n' 'TEST SIGTERM during QMI apply restores the exact profile and interface'
rm -rf "$PERSIST/targets/network_cellqmi" "$CACHE"
mkdir -p "$CACHE"
printf 'v2\tinternet.telekom\tQMI signal fixture\t2026-01-01T00:00:00Z\tfixture-user\tfixture-pass\tpap-or-chap\tipv4v6\n' \
	>"$CACHE/89490200002186275443.tsv"
rm -f "$STATE/qmi-settle-seen" "$STATE/qmi-settle-pid" "$STATE/ifup-seen"
: >"$STATE/events"
BLOCK_QMI_SETTLE=1 TEST_INTERFACE=cellqmi sh "$SCRIPT" apply >/dev/null 2>&1 &
signal_engine_pid=$!
signal_wait=50
while [ ! -e "$STATE/qmi-settle-seen" ] && [ "$signal_wait" -gt 0 ]; do
	/bin/sleep 0.1
	signal_wait=$((signal_wait - 1))
done
[ -e "$STATE/qmi-settle-seen" ] || fail 'QMI signal test did not reach the teardown quiet period'
kill -TERM "$signal_engine_pid"
if wait "$signal_engine_pid"; then
	fail 'interrupted QMI apply returned success'
fi
kill -TERM "$(cat "$STATE/qmi-settle-pid")" 2>/dev/null || :
[ "$(cat "$STATE/qmi-apn")" = qmi.old ] || fail 'SIGTERM did not restore QMI APN'
[ "$(cat "$STATE/qmi-username")" = qmi-user ] || fail 'SIGTERM did not restore QMI username'
[ "$(cat "$STATE/qmi-password")" = qmi-pass ] || fail 'SIGTERM did not restore QMI password'
[ "$(cat "$STATE/qmi-auth")" = chap ] || fail 'SIGTERM did not restore QMI auth'
[ "$(cat "$STATE/qmi-pdptype")" = ip ] || fail 'SIGTERM did not restore QMI PDP type'
[ "$(tail -n 1 "$STATE/events")" = 'up cellqmi' ] || fail 'SIGTERM rollback left the QMI interface down'
TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1

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

printf '%s\n' 'TEST identity values containing carriage returns fail closed'
MM_SERVING_OPERATOR_NAME="$(printf 'forged\routput')"
export MM_SERVING_OPERATOR_NAME
if sh "$SCRIPT" status >/dev/null 2>&1; then
	fail 'carriage return in modem identity output was accepted'
fi
unset MM_SERVING_OPERATOR_NAME

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
UBUS_L3_DEVICE=wwan_runtime
export CURL_SUCCESS_APN UBUS_L3_DEVICE
sh "$SCRIPT" apply
[ "$(cat "$STATE/curl-device")" = wwan_runtime ] || fail 'connectivity test ignored netifd l3_device'
unset UBUS_L3_DEVICE
[ "$(cat "$STATE/apn")" = 'internet.telekom' ] || fail 'working APN not kept'
[ "$(cat "$STATE/username")" = 'fixture-user' ] || fail 'working username not kept'
[ "$(cat "$STATE/password")" = 'fixture-pass' ] || fail 'working password not kept'
[ "$(cat "$STATE/allowedauth")" = 'pap chap' ] || fail 'working authentication not kept'
[ "$(cat "$STATE/iptype")" = 'ipv4v6' ] || fail 'working IP type not kept'
[ -s "$CACHE/89490200002186275443.tsv" ] || fail 'ICCID cache missing'
grep -F -q 'internet.telekom' "$CACHE/89490200002186275443.tsv" || fail 'cache APN missing'
grep -F -q 'fixture-user' "$CACHE/89490200002186275443.tsv" || fail 'cache profile missing'
[ -s "$TARGET_PERSIST/baseline.tsv" ] || fail 'target-scoped pre-apply APN baseline missing'
[ -s "$TARGET_PERSIST/active.tsv" ] || fail 'target-scoped reconciled SIM state missing'
[ "$(file_mode "$TARGET_PERSIST")" = 700 ] || fail 'target state directory is not mode 0700'
[ "$(file_mode "$TARGET_PERSIST/baseline.tsv")" = 600 ] || fail 'baseline is not mode 0600'
[ "$(file_mode "$TARGET_PERSIST/active.tsv")" = 600 ] || fail 'active state is not mode 0600'
[ "$(file_mode "$CACHE/89490200002186275443.tsv")" = 600 ] || fail 'credential cache is not mode 0600'

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
[ "$(cat "$CACHE/last-result-code")" = success ] || fail 'idempotent connectivity verification left a stale failure result'

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
grep -F -q '89492031246010483050' "$TARGET_PERSIST/active.tsv" || fail 'changed ICCID was not recorded as reconciled'
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
[ ! -e "$TARGET_PERSIST/baseline.tsv" ] || fail 'reset left baseline behind'
[ ! -e "$TARGET_PERSIST/active.tsv" ] || fail 'reset left reconciled SIM state behind'
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
grep -F -q 'v3' "$TARGET_PERSIST/baseline.tsv" || fail 'legacy baseline was not migrated into v3 target state'
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
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["version"] == "v2"; assert d["target_capabilities"]["profile_apply"] is True and d["target_implementation_state"] == "stable" and d["target_hardware_validated"] is True; assert d["hardware_integration"] == "huasifei-wh3000-gpio-v1"; assert d["configured_apn"] == "rollback.apn"; assert d["interface_up"] is True; assert d["registration_state"] == "home"; assert d["roaming"] is False; assert d["roaming_policy"] == "default-allow"; assert d["serving_operator_id"] == "26201"; assert d["database_version"] == "2026.07.16"; assert d["database_format"] == "2"; assert d["database_sources"] == "fixture"; assert d["database_revisions"] == "fixture@1234567"; assert d["database_path"] == sys.argv[2]' "$status_json" "$DB" || fail 'invalid status JSON'
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
mkdir -p "$TARGET_PERSIST"
printf 'v2\t89380062300756308069\tinternet.telekom\tfixture-user\tfixture-pass\tpap chap\tipv4v6\n' \
	>"$TARGET_PERSIST/active.tsv"
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
rm -f "$STATE/allow_roaming" "$STATE/ifup-seen" "$TARGET_PERSIST/active.tsv"

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

printf '%s\n' 'TEST ModemManager calls remain bounded without an external timeout command'
rm -f "$STATE/mmcli-hang-pid"
bounded_started="$(date +%s)"
if MMCLI_UNAVAILABLE=0 MMCLI_HANG=1 TEST_INTERFACE=wwan \
	APN_AUTOCONFIG_TIMEOUT="$TESTROOT/missing-timeout" \
	APN_AUTOCONFIG_MMCLI_TIMEOUT_SECONDS=1 sh "$SCRIPT" status >/dev/null 2>&1; then
	fail 'a hanging mmcli call unexpectedly produced status output'
else
	[ "$?" -eq 3 ] || fail 'a hanging mmcli call did not remain retryable'
fi
bounded_elapsed=$(($(date +%s) - bounded_started))
[ "$bounded_elapsed" -le 5 ] || fail "fallback mmcli timeout took ${bounded_elapsed}s"
mmcli_hang_pid="$(cat "$STATE/mmcli-hang-pid" 2>/dev/null || :)"
[ -n "$mmcli_hang_pid" ] || fail 'hanging mmcli fixture did not start'
if kill -0 "$mmcli_hang_pid" 2>/dev/null; then
	fail 'fallback mmcli timeout left its child process running'
fi

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
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["busy"] is True and d["action"] == "reconcile" and d["target_id"] == "network:wwan"' "$busy_json" || fail 'running action or its target not reported'
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
[ "$(file_mode "$TEST_ACTION_STATE")" = 700 ] || fail 'action state directory is not mode 0700'
[ "$(file_mode "$TEST_ACTION_STATE/state.tsv")" = 600 ] || fail 'action state file is not mode 0600'

printf '%s\n' 'TEST action worker forwards SIGTERM and protects its state file'
cat >"$MOCKBIN/apn-autoconfig-signal-command" <<'EOF'
#!/bin/sh
trap ': >"$TEST_STATE/worker-child-terminated"; exit 143' TERM
: >"$TEST_STATE/worker-child-ready"
while :; do /bin/sleep 1; done
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-signal-command"
rm -rf "$TEST_ACTION_STATE"
mkdir -p "$TEST_ACTION_STATE"
rm -f "$STATE/worker-child-ready" "$STATE/worker-child-terminated"
(
	umask 022
	export APN_AUTOCONFIG_ACTION_COMMAND="$MOCKBIN/apn-autoconfig-signal-command"
	exec sh "$BASE/files/usr/libexec/apn-autoconfig-action" reconcile \
		"$TEST_ACTION_STATE" 2026-08-11T00:00:00Z network:wwan
) >/dev/null 2>&1 &
action_worker_pid=$!
signal_wait=50
while [ ! -e "$STATE/worker-child-ready" ] && [ "$signal_wait" -gt 0 ]; do
	/bin/sleep 0.1
	signal_wait=$((signal_wait - 1))
done
[ -e "$STATE/worker-child-ready" ] || fail 'action worker signal child did not start'
kill -TERM "$action_worker_pid"
if wait "$action_worker_pid"; then fail 'interrupted action worker returned success'; fi
[ -e "$STATE/worker-child-terminated" ] || fail 'action worker did not forward SIGTERM to its child'
[ "$(file_mode "$TEST_ACTION_STATE/state.tsv")" = 600 ] || fail 'action state file is not mode 0600'
grep -F -q "$(printf 'v2\tfailed\treconcile')" "$TEST_ACTION_STATE/state.tsv" || \
	fail 'interrupted action worker did not publish terminal state'

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
grep -F -x -q 'roaming-policy-set allow --target network:wwan' "$STATE/policy-action-args" || fail 'roaming-allow action lost its target or used the wrong command'
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

# ---- 0.11.0 provisioning support ----
#
# See docs/provisioning-contract-v1.md. Provisioning inverts the existing
# borrow direction: apn-autoconfig-modem owns the global lock and this engine
# borrows it. The variable alone must never grant the lock.

printf '%s\n' 'TEST the operation lock is borrowed only by proving live ownership'
rm -rf "$TEST_ACTION_STATE" "$TEST_LOCK"
mkdir -p "$(dirname "$TEST_LOCK")"
printf '%s\n' "$$" >"$TEST_LOCK"
borrow_status=0
APN_AUTOCONFIG_LOCK_OWNER_PID=999999 sh "$SCRIPT" reconcile >/dev/null 2>"$STATE/borrow-mismatch.err" || \
	borrow_status=$?
[ "$borrow_status" -eq 3 ] || fail "a borrow PID that does not own the lock exited $borrow_status instead of 3"
grep -q 'did not prove ownership' "$STATE/borrow-mismatch.err" || \
	fail 'a borrow PID that does not own the lock was not refused as unproven ownership'

rm -f "$TEST_LOCK"
borrow_status=0
APN_AUTOCONFIG_LOCK_OWNER_PID="$$" sh "$SCRIPT" reconcile >/dev/null 2>"$STATE/borrow-nolock.err" || \
	borrow_status=$?
[ "$borrow_status" -eq 3 ] || fail "a borrow claim with no lock at all exited $borrow_status instead of 3"
grep -q 'did not prove ownership' "$STATE/borrow-nolock.err" || \
	fail 'an environment variable alone was treated as lock ownership'

if kill -0 999999 2>/dev/null; then
	printf 'SKIP: PID 999999 is unexpectedly alive on this host\n'
else
	printf '%s\n' 999999 >"$TEST_LOCK"
	borrow_status=0
	APN_AUTOCONFIG_LOCK_OWNER_PID=999999 sh "$SCRIPT" reconcile >/dev/null 2>"$STATE/borrow-dead.err" || \
		borrow_status=$?
	[ "$borrow_status" -eq 3 ] || \
		fail "a borrow claim naming a dead owner exited $borrow_status instead of 3"
	grep -q 'did not prove ownership' "$STATE/borrow-dead.err" || \
		fail 'a dead owner recorded in the lock was accepted as a live borrow'
fi
rm -f "$TEST_LOCK"

printf '%s\n' 'TEST the manual profile reaches the engine without the password ever being an argument'
rm -rf "$TEST_LOCK" "$TEST_ACTION_STATE"
manual_probe="$STATE/manual-engine-probe"
cat >"$manual_probe" <<'PROBEEOF'
#!/bin/sh
# Stands in for the engine and records exactly how it was invoked, including
# whether the manual profile was still present in its environment.
printf 'argv:%s\n' "$*" >>"$TEST_STATE/manual-invocation"
printf 'stdin:%s\n' "$(cat)" >>"$TEST_STATE/manual-invocation"
printf 'env_password:%s\n' "${APN_AUTOCONFIG_MANUAL_PASSWORD:-<unset>}" >>"$TEST_STATE/manual-invocation"
printf 'env_apn:%s\n' "${APN_AUTOCONFIG_MANUAL_APN:-<unset>}" >>"$TEST_STATE/manual-invocation"
exit 0
PROBEEOF
chmod 0755 "$manual_probe"
: >"$STATE/manual-invocation"
mkdir -p "$TEST_ACTION_STATE"
APN_AUTOCONFIG_ACTION_COMMAND="$manual_probe" \
	APN_AUTOCONFIG_MANUAL_APN=manual.example \
	APN_AUTOCONFIG_MANUAL_USERNAME=someone \
	APN_AUTOCONFIG_MANUAL_PASSWORD='top secret' \
	APN_AUTOCONFIG_MANUAL_AUTH=pap \
	APN_AUTOCONFIG_MANUAL_IP_TYPE=ipv4 \
	sh "$BASE/files/usr/libexec/apn-autoconfig-action" apply-manual "$TEST_ACTION_STATE" '2026-01-01T00:00:00Z' network:wwan
manual_seen="$(cat "$STATE/manual-invocation")"
# Only the argv line: a glob over the whole record would also match the
# password on the stdin line and report a leak that is not there.
manual_argv="$(grep '^argv:' "$STATE/manual-invocation")"
case "$manual_argv" in
	*"top secret"*) fail 'the worker passed the password as a command argument' ;;
esac
assert_contains "$manual_seen" 'stdin:top secret'
for needle in '--password-stdin' '--apn manual.example' '--username someone' \
	'--auth pap' '--ip-type ipv4' '--target network:wwan'
do
	case "$manual_argv" in
		*"$needle"*) : ;;
		*) fail "the engine was not given $needle" ;;
	esac
done
# The profile must be gone from the environment before the engine runs, so it
# cannot reach curl, mmcli, ifup or anything else the engine spawns.
assert_contains "$manual_seen" 'env_password:<unset>'
assert_contains "$manual_seen" 'env_apn:<unset>'

printf '%s\n' 'TEST a manual profile without credentials sends no credential options'
: >"$STATE/manual-invocation"
rm -rf "$TEST_ACTION_STATE"
mkdir -p "$TEST_ACTION_STATE"
APN_AUTOCONFIG_ACTION_COMMAND="$manual_probe" \
	APN_AUTOCONFIG_MANUAL_APN=plain.example \
	sh "$BASE/files/usr/libexec/apn-autoconfig-action" apply-manual "$TEST_ACTION_STATE" '2026-01-01T00:00:00Z' network:wwan
manual_argv="$(grep '^argv:' "$STATE/manual-invocation")"
manual_seen="$(cat "$STATE/manual-invocation")"
case "$manual_argv" in
	*--username*) fail 'a credential-free manual profile still sent a username' ;;
	*--password-stdin*) fail 'a credential-free manual profile still asked for a password' ;;
esac
case "$manual_argv" in
	*'--apn plain.example'*) : ;;
	*) fail 'the engine was not given the manual APN' ;;
esac

printf '%s\n' 'TEST the control wrapper refuses a manual profile it cannot validate'
for bad_target in '' 'wwan' 'network:' 'network:../etc' 'network:a b'; do
	bad_status=0
	APN_AUTOCONFIG_MANUAL_APN=ok.example \
		sh "$CONTROL_SCRIPT" apply-manual "$bad_target" >/dev/null 2>&1 || bad_status=$?
	[ "$bad_status" -eq 2 ] || fail "the control wrapper accepted the unsafe target '$bad_target'"
done
bad_status=0
sh "$CONTROL_SCRIPT" apply-manual network:wwan >/dev/null 2>&1 || bad_status=$?
[ "$bad_status" -eq 2 ] || fail 'the control wrapper started a manual profile with no APN in the environment'

printf '%s\n' 'TEST apply-manual applies a user profile through the normal candidate path'
rm -rf "$TEST_LOCK"
CURL_SUCCESS_APN=manual.example
export CURL_SUCCESS_APN
rm -f "$TARGET_PERSIST/baseline.tsv" "$TARGET_PERSIST/active.tsv"
sh "$SCRIPT" apply-manual --apn manual.example >/dev/null 2>&1 || \
	fail 'apply-manual failed for a profile that connects'
[ "$(cat "$STATE/apn")" = manual.example ] || fail 'apply-manual did not write the requested APN'
[ -s "$TARGET_PERSIST/baseline.tsv" ] || fail 'apply-manual did not capture a baseline before writing'
[ -s "$TARGET_PERSIST/active.tsv" ] || fail 'apply-manual did not record reconciled state'
grep -F -q 'manual.example' "$TARGET_PERSIST/active.tsv" || \
	fail 'reconciled state does not name the manually applied APN'
grep -F -q 'manual' "$CACHE/last-result" || \
	fail 'the recorded result does not identify the profile as manual'

printf '%s\n' 'TEST apply-manual stores optional credentials it was given'
rm -rf "$TEST_LOCK"
CURL_SUCCESS_APN=creds.example
export CURL_SUCCESS_APN
printf '%s\n' 'sekrit' | sh "$SCRIPT" apply-manual --apn creds.example \
	--username someone --password-stdin --auth pap --ip-type ipv4 >/dev/null 2>&1 || \
	fail 'apply-manual failed with a full credential set'
[ "$(cat "$STATE/username")" = someone ] || fail 'apply-manual did not write the username'
[ "$(cat "$STATE/password")" = sekrit ] || fail 'apply-manual did not read the password from stdin'
[ "$(cat "$STATE/allowedauth")" = pap ] || fail 'apply-manual did not write the authentication mode'
[ "$(cat "$STATE/iptype")" = ipv4 ] || fail 'apply-manual did not write the IP family'

printf '%s\n' 'TEST a failing manual profile restores the exact previous profile'
rm -rf "$TEST_LOCK"
CURL_SUCCESS_APN=creds.example
export CURL_SUCCESS_APN
manual_fail_status=0
sh "$SCRIPT" apply-manual --apn nothere.example >/dev/null 2>&1 || manual_fail_status=$?
[ "$manual_fail_status" -ne 0 ] || fail 'a manual profile with no connectivity reported success'
[ "$(cat "$STATE/apn")" = creds.example ] || \
	fail "a failed manual profile left APN '$(cat "$STATE/apn")' instead of restoring creds.example"
[ "$(cat "$STATE/username")" = someone ] || fail 'rollback did not restore the previous username'
[ "$(cat "$STATE/password")" = sekrit ] || fail 'rollback did not restore the previous password'

printf '%s\n' 'TEST apply-manual validates its input before touching the network'
rm -rf "$TEST_LOCK"
: >"$STATE/events"
manual_before="$(cat "$STATE/apn")"
for bad_case in \
	'--apn' \
	'--apn bad/apn' \
	'--apn ok.example --auth wrong' \
	'--apn ok.example --ip-type ipv5' \
	'--apn ok.example --username someone'
do
	bad_status=0
	# shellcheck disable=SC2086
	sh "$SCRIPT" apply-manual $bad_case >/dev/null 2>&1 || bad_status=$?
	[ "$bad_status" -eq 2 ] || \
		fail "apply-manual $bad_case exited $bad_status instead of the usage class 2"
done
[ ! -s "$STATE/events" ] || fail 'a rejected manual profile still restarted the interface'
[ "$(cat "$STATE/apn")" = "$manual_before" ] || fail 'a rejected manual profile changed the APN'

printf '%s\n' 'TEST the manual password is never accepted as a command-line argument'
rm -rf "$TEST_LOCK"
argv_status=0
sh "$SCRIPT" apply-manual --apn ok.example --username u --password secret \
	>/dev/null 2>"$STATE/argv-password.err" || argv_status=$?
[ "$argv_status" -ne 0 ] || fail 'apply-manual accepted a password as an argument, exposing it through ps'
grep -q -- '--password' "$STATE/argv-password.err" || \
	fail 'the password argument was rejected for some unrelated reason'

printf '%s\n' 'TEST manual profile options are refused for other commands'
rm -rf "$TEST_LOCK"
sneaky_status=0
sh "$SCRIPT" reconcile --apn sneaky.example >/dev/null 2>"$STATE/sneaky.err" || sneaky_status=$?
[ "$sneaky_status" -ne 0 ] || fail 'reconcile accepted manual profile options'
grep -q 'only valid for apply-manual' "$STATE/sneaky.err" || \
	fail 'manual options on reconcile were refused for some unrelated reason'

printf '%s\n' 'TEST a manual profile survives a later reconcile and is retried before the database'
rm -rf "$TEST_LOCK"
CURL_SUCCESS_APN=survives.example
export CURL_SUCCESS_APN
sh "$SCRIPT" apply-manual --apn survives.example >/dev/null 2>&1 || \
	fail 'setup for the reconcile-preference test failed'
: >"$STATE/events"
sh "$SCRIPT" reconcile >/dev/null 2>&1 || fail 'reconcile failed on a working manual profile'
[ "$(cat "$STATE/apn")" = survives.example ] || \
	fail 'reconcile replaced a working manual profile with a database candidate'
[ ! -s "$STATE/events" ] || fail 'reconcile restarted the interface for an already working manual profile'
# When it stops verifying, the manual profile must still be tried first.
printf '%s\n' 'wrong.apn' >"$STATE/apn"
sh "$SCRIPT" reconcile >/dev/null 2>&1 || fail 'reconcile failed while restoring the manual profile'
[ "$(cat "$STATE/apn")" = survives.example ] || \
	fail 'reconcile did not restore the manual profile before falling back to the database'

printf '%s\n' 'TEST apply-manual works without the provider database it does not consult'
rm -rf "$TEST_LOCK"
CURL_SUCCESS_APN=nodb.example
export CURL_SUCCESS_APN
mv "$DB" "$DB.hidden"
nodb_status=0
sh "$SCRIPT" apply-manual --apn nodb.example >/dev/null 2>&1 || nodb_status=$?
mv "$DB.hidden" "$DB"
[ "$nodb_status" -eq 0 ] || \
	fail "apply-manual needed the provider database it does not consult (exit $nodb_status)"
[ "$(cat "$STATE/apn")" = nodb.example ] || \
	fail 'apply-manual did not apply the profile without a database'

printf '%s\n' 'TEST forget-target drops one target and leaves the shared cache alone'
rm -rf "$TEST_LOCK"
mkdir -p "$PERSIST/targets/network_apnmodem1" "$PERSIST/targets/network_cellqmi" "$CACHE"
printf 'v3\tapnmodem1\tnetwork:apnmodem1\tmodemmanager\tmodemmanager\n' \
	>"$PERSIST/targets/network_apnmodem1/baseline.tsv"
printf 'v3\t8949\tweb.example\t-\t-\t-\t-\tnetwork:apnmodem1\tmodemmanager\n' \
	>"$PERSIST/targets/network_apnmodem1/active.tsv"
printf 'v3\tcellqmi\tnetwork:cellqmi\tqmi\tqmi\n' \
	>"$PERSIST/targets/network_cellqmi/baseline.tsv"
printf 'keep-me\n' >"$CACHE/shared-cache-entry.tsv"
sh "$SCRIPT" forget-target --target network:apnmodem1 >/dev/null 2>&1 || \
	fail 'forget-target failed for a section that no longer exists'
[ ! -e "$PERSIST/targets/network_apnmodem1" ] || \
	fail 'forget-target left the target state behind'
[ -f "$PERSIST/targets/network_cellqmi/baseline.tsv" ] || \
	fail 'forget-target removed an unrelated target state'
[ -f "$CACHE/shared-cache-entry.tsv" ] || \
	fail 'forget-target cleared the cache shared by every target'

printf '%s\n' 'TEST forget-target refuses while the network section still exists'
mkdir -p "$PERSIST/targets/network_wwan"
printf 'v3\twwan\tnetwork:wwan\tmodemmanager\tmodemmanager\n' \
	>"$PERSIST/targets/network_wwan/baseline.tsv"
forget_status=0
sh "$SCRIPT" forget-target --target network:wwan >/dev/null 2>&1 || forget_status=$?
[ "$forget_status" -eq 4 ] || \
	fail "forget-target on a live section exited $forget_status instead of the blocked class 4"
[ -f "$PERSIST/targets/network_wwan/baseline.tsv" ] || \
	fail 'forget-target stranded a live target by dropping the baseline that restores it'

printf '%s\n' 'TEST forget-target requires an explicit target and rejects an unsafe one'
if sh "$SCRIPT" forget-target >/dev/null 2>&1; then
	fail 'forget-target ran without --target'
fi
if sh "$SCRIPT" forget-target --target 'network:../../tmp/x' >/dev/null 2>&1; then
	fail 'forget-target accepted an unsafe target ID'
fi

printf '%s\n' 'TEST forget-target is a no-op when there is no state for the target'
sh "$SCRIPT" forget-target --target network:neverexisted >/dev/null 2>&1 || \
	fail 'forget-target failed when there was nothing to forget'

printf '%s\n' 'TEST a disabled project-owned staging section never joins automatic target selection'
TEST_SINGLE_TARGET=1
export TEST_SINGLE_TARGET
auto_out="$(TEST_INTERFACE=auto sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["target_id"] == "network:wwan", json.loads(sys.argv[1])' \
	"$auto_out" || fail 'the single writable target was not selected automatically'
TEST_STAGING_SECTION=1
export TEST_STAGING_SECTION
auto_out="$(TEST_INTERFACE=auto sh "$SCRIPT" status-json)"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["target_id"] == "network:wwan", json.loads(sys.argv[1])' \
	"$auto_out" || fail 'a disabled staging section made automatic target selection ambiguous'

printf '%s\n' 'TEST an explicit target still selects a disabled staging section'
staged_out="$(sh "$SCRIPT" status-json --target network:apnmodem1)"
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["target_id"] == "network:apnmodem1", json.loads(sys.argv[1])' \
	"$staged_out" || fail 'an explicit --target did not select the staging section'

printf '%s\n' 'TEST a promoted project-owned section participates in automatic selection again'
TEST_STAGING_PROMOTED=1
export TEST_STAGING_PROMOTED
if TEST_INTERFACE=auto sh "$SCRIPT" status-json >/dev/null 2>&1; then
	fail 'a promoted second writable target did not make automatic selection ambiguous'
else
	[ "$?" -eq 4 ] || fail 'ambiguous automatic selection after promotion used the wrong exit code'
fi
TEST_STAGING_PROMOTED=0
TEST_STAGING_SECTION=0
TEST_SINGLE_TARGET=0
export TEST_STAGING_PROMOTED TEST_STAGING_SECTION TEST_SINGLE_TARGET

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

printf '%s\n' 'TEST boot worker forwards SIGTERM to reconcile'
grep -F -q 'procd_set_param term_timeout 30' "$BASE/files/etc/init.d/apn-autoconfig" || \
	fail 'procd termination window no longer covers bounded request and QMI rollback'
rm -f "$STATE/worker-child-ready" "$STATE/worker-child-terminated"
TEST_AUTOSTART=1 APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-signal-command" \
	sh "$BOOT_SCRIPT" >/dev/null 2>&1 &
boot_worker_pid=$!
signal_wait=50
while [ ! -e "$STATE/worker-child-ready" ] && [ "$signal_wait" -gt 0 ]; do
	/bin/sleep 0.1
	signal_wait=$((signal_wait - 1))
done
[ -e "$STATE/worker-child-ready" ] || fail 'boot worker signal child did not start'
kill -TERM "$boot_worker_pid"
if wait "$boot_worker_pid"; then fail 'interrupted boot worker returned success'; fi
[ -e "$STATE/worker-child-terminated" ] || fail 'boot worker did not forward SIGTERM to reconcile'

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

printf '%s\n' 'TEST board modem reset uses the selected QMI backend after power returns'
: >"$STATE/events"
rm -f "$STATE/qmi-reset-order" "$STATE/ifup-seen"
QMI_TRACE_RESET_ORDER=1
export QMI_TRACE_RESET_ORDER
TEST_INTERFACE=cellqmi sh "$SCRIPT" modem-reset >/dev/null 2>&1
[ "$(cat "$TEST_GPIO")" = 0 ] || fail 'QMI modem reset left modem power off'
[ "$(cat "$STATE/qmi-apn")" = internet.telekom ] || fail 'QMI modem reset did not reconcile APN'
grep -F -q 'down cellqmi' "$STATE/events" || fail 'QMI modem reset did not stop its selected target'
grep -F -q 'up cellqmi' "$STATE/events" || fail 'QMI modem reset did not restore its selected target'
[ "$(sed -n '1p' "$STATE/qmi-reset-order")" = identity ] || fail 'QMI modem reset did not first wait for SIM identity'
[ "$(sed -n '2p' "$STATE/qmi-reset-order")" = up ] || fail 'QMI modem reset queried identity again before handing control to netifd'
[ "$(sed -n '3p' "$STATE/qmi-reset-order")" = data ] || fail 'QMI modem reset did not wait for its data interface before reconciling'
unset QMI_TRACE_RESET_ORDER
TEST_INTERFACE=cellqmi sh "$SCRIPT" reset >/dev/null 2>&1

printf '%s\n' 'TEST QMI modem reset does not query identity before its data interface is ready'
: >"$STATE/events"
rm -f "$STATE/ifup-seen"
if QMI_DATA_UNAVAILABLE=1 TEST_INTERFACE=cellqmi sh "$SCRIPT" modem-reset >/dev/null 2>&1; then
	fail 'QMI modem reset continued without a ready data interface'
else
	[ "$?" -eq 3 ] || fail 'missing QMI data interface did not return retryable status'
fi
[ "$(grep -c '^up cellqmi$' "$STATE/events")" -ge 1 ] || fail 'failed QMI data readiness did not attempt interface recovery'

printf '%s\n' 'TEST modem reset is unavailable without a board integration package'
: >"$STATE/events"
if APN_AUTOCONFIG_HARDWARE_INTEGRATION="$TESTROOT/missing-hardware-integration" \
	sh "$SCRIPT" modem-reset >/dev/null 2>&1; then
	fail 'modem reset ran without a board integration'
else
	[ "$?" -eq 4 ] || fail 'missing board integration did not use the target-contract exit code'
fi
[ ! -s "$STATE/events" ] || fail 'missing board integration changed network state'

printf '%s\n' 'TEST failed modem return leaves power on and attempts WWAN recovery'
: >"$STATE/events"
if MMCLI_UNAVAILABLE=1 sh "$SCRIPT" modem-reset >/dev/null 2>&1; then
	fail 'modem reset unexpectedly succeeded while ModemManager was unavailable'
fi
[ "$(cat "$TEST_GPIO")" = '0' ] || fail 'failed modem reset left modem power off'
grep -F -q 'up wwan' "$STATE/events" || fail 'failed modem reset did not attempt WWAN recovery'

printf '%s\n' 'TEST coordinator delegation preserves failure status and runs reconcile only after success'
cat >"$MOCKBIN/apn-autoconfig-modem" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_STATE/coordinator-calls"
case "${1:-}" in
	resolve) printf '%s\n' 'imei:490154203237518' ;;
	status-json) printf '%s\n' '{"version":"v1","capabilities":{"reset":true}}' ;;
	reset)
		status="${TEST_COORDINATOR_RESET_EXIT:-0}"
		[ "$status" -ne 0 ] || : >"$TEST_STATE/coordinator-reset-complete"
		exit "$status"
	;;
	*) exit 2 ;;
esac
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-modem"
: >"$STATE/coordinator-calls"
if TEST_COORDINATOR_RESET_EXIT=7 sh "$SCRIPT" modem-reset >/dev/null 2>&1; then
	fail 'coordinator reset failure was converted into success'
else
	[ "$?" -eq 7 ] || fail 'coordinator reset failure did not preserve exit code 7'
fi
printf '%s\n' 'wrong.apn' >"$STATE/apn"
rm -f "$STATE/coordinator-reset-complete" "$STATE/coordinator-mm-count" "$STATE/coordinator-sim-ready"
MM_DELAY_AFTER_COORDINATOR=1 TEST_COORDINATOR_RESET_EXIT=0 sh "$SCRIPT" modem-reset >/dev/null 2>&1 || \
	fail 'successful coordinator reset did not continue to APN reconcile'
[ "$(cat "$STATE/coordinator-mm-count")" -ge 3 ] || fail 'core did not poll until the primary SIM became readable'
[ -e "$STATE/coordinator-sim-ready" ] || fail 'core reconciled before the primary SIM became readable'
[ "$(cat "$STATE/apn")" = internet.telekom ] || fail 'successful coordinator reset did not reconcile APN'
grep -F -x -q 'resolve --interface wwan' "$STATE/coordinator-calls" || fail 'compatibility shim did not resolve the selected interface'
grep -F -x -q 'reset --modem imei:490154203237518' "$STATE/coordinator-calls" || fail 'compatibility shim did not invoke coordinator reset'
rm -f "$MOCKBIN/apn-autoconfig-modem"

printf '%s\n' 'TEST button ignores press and queues modem reset only on release'
cat >"$MOCKBIN/apn-autoconfig-button-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_STATE/button-calls"
case "${TEST_BUTTON_LAUNCH_RESULT:-accepted}" in
	accepted) printf '%s\n' '{"version":"v2","accepted":true,"busy":true,"state":"running"}' ;;
	busy) printf '%s\n' '{"version":"v2","accepted":false,"busy":true,"state":"running"}' ;;
	rejected) printf '%s\n' '{"version":"v2","accepted":false,"busy":false,"state":"failed"}' ;;
	malformed) printf '%s\n' 'not-json' ;;
	failure) exit 7 ;;
esac
EOF
chmod 0755 "$MOCKBIN/apn-autoconfig-button-command"
rm -f "$STATE/button-calls" "$STATE/button-logger-calls"
TEST_BUTTON_ENABLED=0 BUTTON=BTN_0 ACTION=released \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
[ ! -e "$STATE/button-calls" ] || fail 'disabled button queued modem-reset'
TEST_BUTTON_ENABLED=1 BUTTON=BTN_0 ACTION=pressed \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
[ ! -e "$STATE/button-calls" ] || fail 'button press triggered the action before release'
TEST_BUTTON_ENABLED=1 BUTTON=BTN_0 ACTION=released \
	TEST_LOGGER_CALLS="$STATE/button-logger-calls" \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
button_wait=10
while [ ! -e "$STATE/button-calls" ] && [ "$button_wait" -gt 0 ]; do
	/bin/sleep 1
	button_wait=$((button_wait - 1))
done
grep -F -x -q 'action-start modem-reset' "$STATE/button-calls" || \
	fail 'button release did not queue modem-reset through the job API'
grep -F -q 'modem reset and APN reconciliation accepted' "$STATE/button-logger-calls" || \
	fail 'accepted button release did not log its real launch result'

printf '%s\n' 'TEST repeated button release reports busy coalescing instead of a second launch'
: >"$STATE/button-calls"
: >"$STATE/button-logger-calls"
TEST_BUTTON_ENABLED=1 TEST_BUTTON_LAUNCH_RESULT=busy BUTTON=BTN_0 ACTION=released \
	TEST_LOGGER_CALLS="$STATE/button-logger-calls" \
	APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
	sh "$BUTTON_SCRIPT"
[ "$(grep -F -x -c 'action-start modem-reset' "$STATE/button-calls")" -eq 1 ] || \
	fail 'busy button release invoked more than one launch request'
grep -F -q 'operation is already running; duplicate ignored' "$STATE/button-logger-calls" || \
	fail 'busy button release was logged as a newly started reset'

printf '%s\n' 'TEST rejected or malformed button launch is an explicit hotplug failure'
for result in rejected malformed failure; do
	if TEST_BUTTON_ENABLED=1 TEST_BUTTON_LAUNCH_RESULT="$result" BUTTON=BTN_0 ACTION=released \
		TEST_LOGGER_CALLS="$STATE/button-logger-calls" \
		APN_AUTOCONFIG_BIN="$MOCKBIN/apn-autoconfig-button-command" \
		sh "$BUTTON_SCRIPT"; then
		fail "button launch result '$result' was converted into success"
	fi
done

printf '%s\n' 'TEST reset-all restores every target baseline before package removal'
rm -rf "$PERSIST/targets"
mkdir -p "$PERSIST/targets/network_wwan"
printf '%s\n' qmi-before-legacy-mismatch >"$STATE/qmi-apn"
printf 'v1\tcellqmi\t1\twrong-interface\n' >"$PERSIST/targets/network_wwan/baseline.tsv"
if sh "$SCRIPT" reset --target network:wwan >/dev/null 2>&1; then
	fail 'legacy baseline for another interface was accepted'
fi
[ "$(cat "$STATE/qmi-apn")" = qmi-before-legacy-mismatch ] || \
	fail 'mismatched legacy baseline changed another interface'
printf 'v2\tcellqmi\noption\tapn\t1\twrong-interface\n' \
	>"$PERSIST/targets/network_wwan/baseline.tsv"
if sh "$SCRIPT" reset --target network:wwan >/dev/null 2>&1; then
	fail 'v2 baseline for another interface was accepted'
fi
[ "$(cat "$STATE/qmi-apn")" = qmi-before-legacy-mismatch ] || \
	fail 'mismatched v2 baseline changed another interface'
rm -rf "$PERSIST/targets"
mkdir -p "$PERSIST/targets/network_wwan"
printf '%s\n' must-not-change >"$STATE/apn"
printf 'v3\twwan\tnetwork:wwan2\tmodemmanager\tmodemmanager\noption\tapn\t1\twrong-target\n' \
	>"$PERSIST/targets/network_wwan/baseline.tsv"
if sh "$SCRIPT" reset --target network:wwan >/dev/null 2>&1; then
	fail 'reset accepted a baseline belonging to another target'
fi
[ "$(cat "$STATE/apn")" = must-not-change ] || fail 'mismatched baseline changed the profile'
rm -rf "$PERSIST/targets"
mkdir -p "$PERSIST/targets/network_wwan" "$PERSIST/targets/network_wwan2"
printf '%s\n' changed-one >"$STATE/apn"
printf '%s\n' changed-two >"$STATE/apn-wwan2"
printf 'v3\twwan\tnetwork:wwan\tmodemmanager\tmodemmanager\noption\tapn\t1\trestored-one\n' \
	>"$PERSIST/targets/network_wwan/baseline.tsv"
printf 'v3\twwan2\tnetwork:wwan2\tmodemmanager\tmodemmanager\noption\tapn\t1\trestored-two\n' \
	>"$PERSIST/targets/network_wwan2/baseline.tsv"
TEST_SECOND_MM=1 sh "$SCRIPT" reset-all >/dev/null 2>&1
[ "$(cat "$STATE/apn")" = restored-one ] || fail 'reset-all did not restore the first target'
[ "$(cat "$STATE/apn-wwan2")" = restored-two ] || fail 'reset-all did not restore the second target'
[ ! -e "$PERSIST/targets/network_wwan/baseline.tsv" ] || fail 'reset-all left the first baseline'
[ ! -e "$PERSIST/targets/network_wwan2/baseline.tsv" ] || fail 'reset-all left the second baseline'

printf '%s\n' 'All tests passed.'
