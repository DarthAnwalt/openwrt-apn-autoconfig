#!/bin/sh
set -eu

# Synthetic contract tests for apn-autoconfig-modem, per
# docs/testing-0.10.0.md and docs/modem-contract-v1.md. Everything here is
# fixture-based: no physical hardware, no SDK build. The Huasifei hardware
# gate and packaging/release gate stay pending for a real router.

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="$(CDPATH= cd -- /tmp && pwd -P)/apn-autoconfig-modem-test.$$"
MOCKBIN="$TESTROOT/bin"
STATE="$TESTROOT/state"
SCRIPT="$BASE/apn-autoconfig-modem/files/usr/sbin/apn-autoconfig-modem"
ACTION_WORKER="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-action"
BOOT_WORKER="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-boot"
HOTPLUG_SCRIPT="$BASE/apn-autoconfig-modem/files/etc/hotplug.d/usb/50-apn-autoconfig-modem"
QUERY_SCRIPT="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-query"
CONTROL_SCRIPT="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-control"
CORE_SCRIPT="$BASE/files/usr/sbin/apn-autoconfig"

cleanup() {
	rm -rf "$TESTROOT" "${TEST_MODEM_ACTION_DIR:-/tmp/apn-autoconfig-modem-action-test.$$}"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$MOCKBIN" "$STATE" "$TESTROOT/sys" "$TESTROOT/run" "$TESTROOT/lock" "$TESTROOT/action"
HARDWARE_MARKER="$TESTROOT/huasifei-wh3000-integration"
GPIO="$TESTROOT/sys/class/gpio/modem_power/value"
mkdir -p "$(dirname "$GPIO")"
printf '%s\n' 0 >"$GPIO"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# ---- mocked environment (uci, ModemManager, netifd, GPIO helpers) ----

: >"$STATE/network-sections"

cat >"$MOCKBIN/uci" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] && shift
case "$1:$2" in
show:network)
	[ -r "$TEST_NETWORK_SECTIONS" ] && cat "$TEST_NETWORK_SECTIONS"
	exit 0
;;
get:apn-autoconfig-modem.main.sysfs_root) printf '%s\n' "$TEST_SYSFS" ;;
get:apn-autoconfig-modem.main.state_dir) printf '%s\n' "$TEST_MODEM_STATE_DIR" ;;
get:apn-autoconfig-modem.main.lock_root) printf '%s\n' "$TEST_MODEM_LOCK_ROOT" ;;
get:apn-autoconfig.main.lock_dir) printf '%s\n' "$TEST_APN_LOCK_DIR" ;;
get:apn-autoconfig.main.qmi_identity_lock_root) printf '%s\n' "$TEST_QMI_IDENTITY_LOCK_ROOT" ;;
get:apn-autoconfig-modem.main.action_state_dir) printf '%s\n' "$TEST_MODEM_ACTION_DIR" ;;
get:apn-autoconfig-modem.main.hotplug_coalesce_seconds) printf '%s\n' "${TEST_HOTPLUG_COALESCE_SECONDS:-0}" ;;
get:apn-autoconfig-modem.main.boot_delay) printf '%s\n' 0 ;;
get:apn-autoconfig-modem.main.provision_metric) printf '%s\n' "${TEST_PROVISION_METRIC-1024}" ;;
get:apn-autoconfig-modem.main.modem_power_path) printf '%s\n' "$TEST_GPIO" ;;
get:apn-autoconfig-modem.main.modem_power_off_value) printf '%s\n' 1 ;;
get:apn-autoconfig-modem.main.modem_power_on_value) printf '%s\n' 0 ;;
get:apn-autoconfig-modem.main.modem_power_off_seconds) printf '%s\n' "${TEST_MODEM_POWER_OFF_SECONDS:-1}" ;;
get:apn-autoconfig-modem.main.modem_wait_seconds) printf '%s\n' "${TEST_MODEM_WAIT_SECONDS:-3}" ;;
get:apn-autoconfig-modem.main.modem_poll_seconds) printf '%s\n' 1 ;;
get:apn-autoconfig-modem.main.connect_wait_seconds) printf '%s\n' "${TEST_CONNECT_WAIT_SECONDS:-2}" ;;
get:apn-autoconfig-modem.main.at_timeout_seconds) printf '%s\n' "${TEST_AT_TIMEOUT_SECONDS:-1}" ;;
get:apn-autoconfig-modem.main.at_port_lock_root) printf '%s\n' "$TEST_AT_PORT_LOCK_ROOT" ;;
get:apn-autoconfig-modem.main.hardware_integration_file) printf '%s\n' "$TEST_HARDWARE_MARKER" ;;
get:apn-autoconfig-modem.main.reset_modem_id) printf '%s\n' "${TEST_RESET_MODEM_ID:-}" ;;
get:network.*)
	section="${2#network.}"
	name="${section%%.*}"
	option="${section#*.}"
	awk -F'\t' -v name="$name" -v option="$option" \
		'$1 == name && $2 == option { print $3; found=1 } END { exit found ? 0 : 1 }' \
		"$TEST_NETWORK_OPTIONS" 2>/dev/null
;;
set:network.*)
	# Every write is journalled so a test can assert exactly which keys were
	# touched, not merely that the end state looks right.
	printf 'set\t%s\n' "$2" >>"$TEST_UCI_WRITES"
	assignment="${2#network.}"
	target="${assignment%%=*}"
	value="${assignment#*=}"
	case "$target" in
		*.*)
			name="${target%%.*}"
			option="${target#*.}"
			tmp="$TEST_NETWORK_OPTIONS.tmp"
			awk -F'\t' -v name="$name" -v option="$option" \
				'!($1 == name && $2 == option)' "$TEST_NETWORK_OPTIONS" >"$tmp" 2>/dev/null || :
			mv "$tmp" "$TEST_NETWORK_OPTIONS"
			printf '%s\t%s\t%s\n' "$name" "$option" "$value" >>"$TEST_NETWORK_OPTIONS"
			tmp="$TEST_NETWORK_SECTIONS.tmp"
			grep -v "^network\.${name}\.${option}=" "$TEST_NETWORK_SECTIONS" >"$tmp" 2>/dev/null || :
			mv "$tmp" "$TEST_NETWORK_SECTIONS"
			printf "network.%s.%s='%s'\n" "$name" "$option" "$value" >>"$TEST_NETWORK_SECTIONS"
		;;
		*)
			grep -q "^network\.${target}=" "$TEST_NETWORK_SECTIONS" 2>/dev/null || \
				printf 'network.%s=%s\n' "$target" "$value" >>"$TEST_NETWORK_SECTIONS"
		;;
	esac
	exit 0
;;
delete:network.*)
	printf 'delete\t%s\n' "$2" >>"$TEST_UCI_WRITES"
	target="${2#network.}"
	case "$target" in
		*.*)
			name="${target%%.*}"
			option="${target#*.}"
			tmp="$TEST_NETWORK_OPTIONS.tmp"
			awk -F'\t' -v name="$name" -v option="$option" \
				'!($1 == name && $2 == option)' "$TEST_NETWORK_OPTIONS" >"$tmp" 2>/dev/null || :
			mv "$tmp" "$TEST_NETWORK_OPTIONS"
			tmp="$TEST_NETWORK_SECTIONS.tmp"
			grep -v "^network\.${name}\.${option}=" "$TEST_NETWORK_SECTIONS" >"$tmp" 2>/dev/null || :
			mv "$tmp" "$TEST_NETWORK_SECTIONS"
		;;
		*)
			tmp="$TEST_NETWORK_OPTIONS.tmp"
			awk -F'\t' -v name="$target" '$1 != name' "$TEST_NETWORK_OPTIONS" >"$tmp" 2>/dev/null || :
			mv "$tmp" "$TEST_NETWORK_OPTIONS"
			tmp="$TEST_NETWORK_SECTIONS.tmp"
			grep -v -E "^network\.${target}(=|\.)" "$TEST_NETWORK_SECTIONS" >"$tmp" 2>/dev/null || :
			mv "$tmp" "$TEST_NETWORK_SECTIONS"
		;;
	esac
	exit 0
;;
commit:*)
	printf 'commit\t%s\n' "${2:-}" >>"$TEST_UCI_WRITES"
	exit 0
;;
revert:*)
	printf 'revert\t%s\n' "${2:-}" >>"$TEST_UCI_WRITES"
	exit 0
;;
*) exit 1 ;;
esac
EOF

cat >"$MOCKBIN/mmcli" <<'EOF'
#!/bin/sh
[ "${MM_UNAVAILABLE:-0}" = 1 ] && exit 1
case "${1:-}" in
-L)
	if [ "${MM_DELAY_AFTER_IFDOWN:-0}" = 1 ] && [ -e "$TEST_STATE/ifdown-seen" ]; then
		count="$(cat "$TEST_STATE/mm-owner-scan-count" 2>/dev/null || printf '%s' 0)"
		count=$((count + 1))
		printf '%s\n' "$count" >"$TEST_STATE/mm-owner-scan-count"
		if [ "$count" -lt 3 ]; then
			exit 0
		fi
		: >"$TEST_STATE/mm-owner-ready"
	fi
	[ -z "${MM_MODEM_INDEX:-}" ] || printf '%s\n' "    /org/freedesktop/ModemManager1/Modem/${MM_MODEM_INDEX}"
	exit 0
;;
-m)
	[ "${2:-}" = "${MM_MODEM_INDEX:-}" ] || exit 1
	if [ "${3:-}" = "--reset" ]; then
		printf '%s\t%s\n' "$2" reset >>"${TEST_MM_RESETS:-/dev/null}"
		[ "${MM_RESET_FAILS:-0}" = 1 ] && exit 1
		# ModemManager's own reset is in-band too: it returns while the modem is
		# still enumerated. The device therefore has to actually leave and come
		# back, or the runtime is right to call the reset ineffective. Removed
		# synchronously, because backgrounding it races the first departure scan
		# and the test would be measuring the scheduler rather than the runtime.
		exit 0
	fi
	printf '%s\n' \
		"modem.generic.device : ${MM_DEVICE:---}" \
		"modem.generic.physdev : ${MM_PHYSDEV:---}" \
		"modem.generic.equipment-identifier : ${MM_IMEI:---}" \
		"modem.generic.manufacturer : ${MM_MANUFACTURER:---}" \
		"modem.generic.model : ${MM_MODEL:---}" \
		"modem.generic.revision : ${MM_REVISION:---}"
	exit 0
;;
esac
exit 1
EOF

cat >"$MOCKBIN/umbim" <<'EOF'
#!/bin/sh
# Recorded, never answered: nothing in inventory or provisioning may open an
# MBIM control channel.
printf '%s\n' "$*" >>"${TEST_UMBIM_CALLS:-/dev/null}"
exit 1
EOF

cat >"$MOCKBIN/uqmi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${TEST_UQMI_CALLS:-/dev/null}"
[ "${UQMI_HANG:-0}" = 1 ] && exec /bin/sleep 30
for arg in "$@"; do
	[ "$arg" = --get-imei ] || continue
	[ -n "${UQMI_IMEI:-}" ] || exit 1
	printf '"%s"\n' "$UQMI_IMEI"
	exit 0
done
exit 1
EOF

cat >"$MOCKBIN/ifdown" <<'EOF'
#!/bin/sh
printf 'down %s\n' "$1" >>"$TEST_EVENTS"
[ "${MM_DELAY_AFTER_IFDOWN:-0}" != 1 ] || : >"$TEST_STATE/ifdown-seen"
EOF

cat >"$MOCKBIN/ifup" <<'EOF'
#!/bin/sh
printf 'up %s\n' "$1" >>"$TEST_EVENTS"
[ "${MM_DELAY_AFTER_IFDOWN:-0}" != 1 ] || [ -e "$TEST_STATE/mm-owner-ready" ] || \
	: >"$TEST_STATE/up-before-owner"
EOF

cat >"$MOCKBIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

# netifd state as seen through ubus. TEST_IFACE_UP names the section netifd
# reports as up, so a connect can be made to succeed or to time out.
cat >"$MOCKBIN/ubus" <<'EOF'
#!/bin/sh
case "${1:-}" in
call)
	section="${2#network.interface.}"
	if [ "$section" = "${TEST_IFACE_UP:-}" ]; then
		printf '{"up":true,"l3_device":"wwan0"}\n'
	else
		printf '{"up":false}\n'
	fi
	exit 0
;;
esac
exit 1
EOF

cat >"$MOCKBIN/jsonfilter" <<'EOF'
#!/bin/sh
expression=""
document=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-e) expression="$2"; shift 2 ;;
		-s) document="$2"; shift 2 ;;
		*) shift ;;
	esac
done
[ -n "$document" ] || document="$(cat)"
key="${expression#@.}"
printf '%s' "$document" | sed -n "s/.*\"${key}\":\([^,}]*\).*/\1/p" | tr -d '"'
EOF

cat >"$MOCKBIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

# An honest bounded timeout. The previous mock exec'd its argument with no
# bound at all, which was harmless while every mocked command returned
# instantly, but silently disabled the very behaviour the AT transport depends
# on. It must also return 124 on expiry, because the code under test
# distinguishes "this port is not a command channel" from "the modem answered
# ERROR", and both look like a nonzero status otherwise. The suite's own `sleep`
# is a no-op, so the watchdog here uses the real one.
cat >"$MOCKBIN/timeout" <<'EOF'
#!/bin/sh
realsleep() { /bin/sleep "$1" 2>/dev/null || /usr/bin/sleep "$1" 2>/dev/null || :; }
seconds="$1"
shift
marker="${TEST_STATE:-/tmp}/.mock-timeout.$$"
rm -f "$marker"
"$@" &
child=$!
(
	realsleep "$seconds"
	: >"$marker"
	kill -TERM "$child" 2>/dev/null || exit 0
	realsleep 1
	kill -9 "$child" 2>/dev/null || :
) >/dev/null 2>&1 &
watchdog=$!
status=0
wait "$child" || status=$?
kill -TERM "$watchdog" 2>/dev/null || :
wait "$watchdog" 2>/dev/null || :
if [ -e "$marker" ]; then
	rm -f "$marker"
	exit 124
fi
rm -f "$marker"
exit "$status"
EOF

# usage: sms_tool -d <device> at <command>
# Behaviour per port comes from TEST_AT_PORTS, and every invocation is
# journalled to TEST_AT_PROBES so a test can assert which ports were probed —
# in particular that a modem's ports were never reached from another modem's
# record, and that discovery probed nothing at all.
cat >"$MOCKBIN/sms_tool" <<'EOF'
#!/bin/sh
realsleep() { /bin/sleep "$1" 2>/dev/null || /usr/bin/sleep "$1" 2>/dev/null || :; }
device=""
at_command=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-d) device="${2:-}"; shift 2 ;;
		at) at_command="${2:-}"; shift 2 ;;
		*) shift ;;
	esac
done
printf '%s\t%s\n' "$device" "$at_command" >>"$TEST_AT_PROBES"
behaviour="$(awk -F'\t' -v d="$device" '$1 == d { print $2; exit }' "$TEST_AT_PORTS" 2>/dev/null)"
[ -n "$behaviour" ] || behaviour=dead
case "$behaviour" in
	dead)
		# Accepts the write and never answers. The majority case on real
		# multi-port modems.
		realsleep 30
		exit 0
	;;
	atonly)
		# Speaks AT without being the control channel, and rejects the model
		# query outright.
		case "$at_command" in
			ATE0|AT) printf 'OK\r\n'; exit 0 ;;
			*) printf 'ERROR\r\n'; exit 1 ;;
		esac
	;;
	atonly-silent)
		# The nastier variant: accepts the model query and answers OK with no
		# model at all. A status check alone would take this for a control port.
		printf 'OK\r\n'
		exit 0
	;;
	control|control-echo)
		# A current modem: EPS registration answers, CESQ carries the NR
		# extension fields, and the standard ICCID spelling works.
		[ "$behaviour" = control-echo ] && printf '%s\r\n' "$at_command"
		case "$at_command" in
			ATE0|AT|AT+COPS=3,2) printf 'OK\r\n'; exit 0 ;;
			AT+CGMI) printf 'Fibocom Wireless Inc.\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGMM) printf '%s\r\n' "${TEST_AT_MODEL:-FM350-GL}"; printf 'OK\r\n'; exit 0 ;;
			AT+CGMR) printf '81600.0000.00.29.21.27\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGSN) printf '%s\r\n' "${TEST_AT_IMEI:-016177002734885}"; printf 'OK\r\n'; exit 0 ;;
			AT+CIMI) printf '%s\r\n' "${TEST_AT_IMSI:-262023103971566}"; printf 'OK\r\n'; exit 0 ;;
			AT+CCID) printf '+CCID: %s\r\n' "${TEST_AT_ICCID:-89492031246010483050}"; printf 'OK\r\n'; exit 0 ;;
			"AT+COPS?") printf '+COPS:0,2,"%s",%s\r\n' "${TEST_AT_PLMN:-26202}" "${TEST_AT_ACT:-13}"; printf 'OK\r\n'; exit 0 ;;
			"AT+CEREG?") printf '+CEREG: 0,%s\r\n' "${TEST_AT_EPS_STAT:-1}"; printf 'OK\r\n'; exit 0 ;;
			AT+CESQ) printf '+CESQ: %s\r\n' "${TEST_AT_CESQ:-29,99,255,255,22,49,255,255,255}"; printf 'OK\r\n'; exit 0 ;;
			AT+CSQ) printf '+CSQ: 12, 99\r\n'; printf 'OK\r\n'; exit 0 ;;
			*) printf 'ERROR\r\n'; exit 1 ;;
		esac
	;;
	control-vanish)
		# Answers like a control port until the reset, which takes the port away
		# as it succeeds: no final OK, and the node really does disappear and
		# come back, because a reset that leaves the modem on the bus is not a
		# reset and the runtime is now required to notice that.
		case "$at_command" in
			"AT+CFUN=1,1")
				exit 1
			;;
			ATE0|AT) printf 'OK\r\n'; exit 0 ;;
			AT+CGMM) printf 'FM350-GL\r\n'; printf 'OK\r\n'; exit 0 ;;
			*) printf 'ERROR\r\n'; exit 1 ;;
		esac
	;;
	control-nosim)
		# Resolves as a control port and answers everything except the SIM.
		# Without this the "no readable SIM" case never gets past resolution,
		# and the identity floor goes untested.
		case "$at_command" in
			ATE0|AT|AT+COPS=3,2) printf 'OK\r\n'; exit 0 ;;
			AT+CGMI) printf 'Fibocom Wireless Inc.\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGMM) printf 'FM350-GL\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGMR) printf '81600.0000.00.29.21.27\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGSN) printf '016177002734885\r\n'; printf 'OK\r\n'; exit 0 ;;
			"AT+CEREG?") printf '+CEREG: 0,0\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CSQ) printf '+CSQ: 99, 99\r\n'; printf 'OK\r\n'; exit 0 ;;
			*) printf '+CME ERROR: SIM not inserted\r\n'; exit 1 ;;
		esac
	;;
	control-legacy)
		# The awkward one, drawn from real replies: only the CS-domain
		# registration answers and it reports stat 6 ("registered, SMS only"),
		# the standard ICCID spelling is rejected, and there is no CESQ.
		case "$at_command" in
			ATE0|AT|AT+COPS=3,2) printf 'OK\r\n'; exit 0 ;;
			AT+CGMI) printf 'Quectel\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGMM) printf 'EC25-E\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGMR) printf 'EC25EFAR06A11M4G\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CGSN) printf '867556043212345\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CIMI) printf '262023103971566\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+QCCID) printf '+QCCID: 89492031246010483050\r\n'; printf 'OK\r\n'; exit 0 ;;
			"AT+COPS?") printf '+COPS:0,2,"26202",7\r\n'; printf 'OK\r\n'; exit 0 ;;
			"AT+CREG?") printf '+CREG: 0,6\r\n'; printf 'OK\r\n'; exit 0 ;;
			AT+CSQ) printf '+CSQ: 12, 99\r\n'; printf 'OK\r\n'; exit 0 ;;
			*) printf 'ERROR\r\n'; exit 1 ;;
		esac
	;;
	*) printf 'ERROR\r\n'; exit 1 ;;
esac
EOF

chmod 0755 "$MOCKBIN"/*
export PATH="$MOCKBIN:/usr/bin:/bin"
export TEST_SYSFS="$TESTROOT/sys"
export TEST_MODEM_STATE_DIR="$TESTROOT/run"
export TEST_MODEM_LOCK_ROOT="$TESTROOT/lock/apn-autoconfig-modem"
export TEST_APN_LOCK_DIR="$TESTROOT/lock/apn-autoconfig.lock"
export TEST_QMI_IDENTITY_LOCK_ROOT="$TESTROOT/lock/apn-autoconfig-qmi-identity"
export TEST_AT_PORT_LOCK_ROOT="$TESTROOT/lock/apn-autoconfig-at-port"
export TEST_AT_PORTS="$STATE/at-ports"
export TEST_MM_RESETS="$STATE/mm-resets"
: >"$STATE/mm-resets"
export TEST_AT_PROBES="$STATE/at-probes"
export TEST_AT_TIMEOUT_SECONDS=1
: >"$STATE/at-ports"
: >"$STATE/at-probes"
export TEST_MODEM_ACTION_DIR="/tmp/apn-autoconfig-modem-action-test.$$"
export TEST_GPIO="$GPIO"
export TEST_HARDWARE_MARKER="$HARDWARE_MARKER"
export TEST_RESET_MODEM_ID=""
export TEST_MODEM_POWER_OFF_SECONDS=1
export TEST_HOTPLUG_COALESCE_SECONDS=0
export TEST_NETWORK_SECTIONS="$STATE/network-sections"
export TEST_NETWORK_OPTIONS="$STATE/network-options"
export TEST_UCI_WRITES="$STATE/uci-writes"
export TEST_EVENTS="$STATE/events"
export TEST_UQMI_CALLS="$STATE/uqmi-calls"
export TEST_UMBIM_CALLS="$STATE/umbim-calls"
export TEST_STATE="$STATE"
export APN_AUTOCONFIG_MODEM_ACTION_WORKER="$ACTION_WORKER"
export APN_AUTOCONFIG_MODEM_ACTION_COMMAND="$SCRIPT"
export APN_AUTOCONFIG_MODEM_BIN="$SCRIPT"

: >"$TEST_NETWORK_SECTIONS"
: >"$TEST_NETWORK_OPTIONS"
: >"$TEST_EVENTS"
: >"$TEST_UQMI_CALLS"
: >"$TEST_UMBIM_CALLS"

reset_network_config() {
	: >"$TEST_NETWORK_SECTIONS"
	: >"$TEST_NETWORK_OPTIONS"
	: >"$TEST_UCI_WRITES"
}

# Every network key the run under test wrote, in order.
uci_writes() {
	cat "$TEST_UCI_WRITES" 2>/dev/null
}

uci_wrote_nothing() {
	[ ! -s "$TEST_UCI_WRITES" ]
}

# Sections other than the named one must never be touched.
uci_touched_only_section() {
	wanted="$1"
	awk -F'\t' -v want="$wanted" '
		$1 == "commit" || $1 == "revert" { next }
		{
			key = $2
			sub(/^network\./, "", key)
			sub(/[.=].*$/, "", key)
			if (key != want) { print key; bad = 1 }
		}
		END { exit bad ? 1 : 0 }
	' "$TEST_UCI_WRITES" 2>/dev/null
}

add_network_section() {
	# name proto [device]
	name="$1"
	proto="$2"
	device="${3:-}"
	printf "network.%s=interface\nnetwork.%s.proto='%s'\n" "$name" "$name" "$proto" >>"$TEST_NETWORK_SECTIONS"
	printf '%s\tproto\t%s\n' "$name" "$proto" >>"$TEST_NETWORK_OPTIONS"
	[ -z "$device" ] || printf '%s\tdevice\t%s\n' "$name" "$device" >>"$TEST_NETWORK_OPTIONS"
}

add_section_option() {
	# section option value
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$TEST_NETWORK_OPTIONS"
}

add_plain_section() {
	# A section with no proto, so it occupies a name without being a target.
	printf 'network.%s=interface\n' "$1" >>"$TEST_NETWORK_SECTIONS"
}

network_section_count() {
	awk -v prefix="$1" '
		$0 ~ ("^network\\." prefix "[0-9]*=") { n++ }
		END { print n + 0 }
	' "$TEST_NETWORK_SECTIONS" 2>/dev/null
}

reset_sysfs() {
	rm -rf "$TESTROOT/sys"
	mkdir -p "$TESTROOT/sys/class/gpio/modem_power" "$TESTROOT/sys/class/usbmisc" \
		"$TESTROOT/sys/class/net" "$TESTROOT/sys/class/tty" "$TESTROOT/sys/class/wwan" \
		"$TESTROOT/sys/bus/usb/drivers/qmi_wwan" "$TESTROOT/sys/bus/usb/drivers/cdc_mbim"
	printf '%s\n' 0 >"$GPIO"
}

# add_qmi_modem <bus-port> <vendor> <product> <serial-or-empty> <wdm-index> [data-iface]
add_qmi_modem() {
	bus_port="$1"; vendor="$2"; product="$3"; serial="$4"; wdm="$5"; data_iface="${6:-}"
	usb_dir="$TESTROOT/sys/devices/platform/mock-usb/$bus_port"
	mkdir -p "$usb_dir/$bus_port:1.4/usbmisc" "$TESTROOT/sys/class/usbmisc/cdc-wdm$wdm"
	printf '%s\n' "$vendor" >"$usb_dir/idVendor"
	printf '%s\n' "$product" >"$usb_dir/idProduct"
	[ -z "$serial" ] || printf '%s\n' "$serial" >"$usb_dir/serial"
	: >"$usb_dir/$bus_port:1.4/usbmisc/cdc-wdm$wdm"
	ln -s "$TESTROOT/sys/bus/usb/drivers/qmi_wwan" "$usb_dir/$bus_port:1.4/driver"
	ln -s "$usb_dir/$bus_port:1.4" "$TESTROOT/sys/class/usbmisc/cdc-wdm$wdm/device"
	if [ -n "$data_iface" ]; then
		mkdir -p "$usb_dir/$bus_port:1.6" "$TESTROOT/sys/class/net/$data_iface"
		ln -s "$usb_dir/$bus_port:1.6" "$TESTROOT/sys/class/net/$data_iface/device"
	fi
}

add_mbim_modem() {
	bus_port="$1"; vendor="$2"; product="$3"; serial="$4"; wdm="$5"; data_iface="${6:-}"
	usb_dir="$TESTROOT/sys/devices/platform/mock-usb/$bus_port"
	mkdir -p "$usb_dir/$bus_port:1.4/usbmisc" "$TESTROOT/sys/class/usbmisc/cdc-wdm$wdm"
	printf '%s\n' "$vendor" >"$usb_dir/idVendor"
	printf '%s\n' "$product" >"$usb_dir/idProduct"
	[ -z "$serial" ] || printf '%s\n' "$serial" >"$usb_dir/serial"
	: >"$usb_dir/$bus_port:1.4/usbmisc/cdc-wdm$wdm"
	ln -s "$TESTROOT/sys/bus/usb/drivers/cdc_mbim" "$usb_dir/$bus_port:1.4/driver"
	ln -s "$usb_dir/$bus_port:1.4" "$TESTROOT/sys/class/usbmisc/cdc-wdm$wdm/device"
	if [ -n "$data_iface" ]; then
		mkdir -p "$usb_dir/$bus_port:1.6" "$TESTROOT/sys/class/net/$data_iface"
		ln -s "$usb_dir/$bus_port:1.6" "$TESTROOT/sys/class/net/$data_iface/device"
	fi
}

add_at_modem() {
	bus_port="$1"; vendor="$2"; product="$3"; serial="$4"; tty_index="$5"
	usb_dir="$TESTROOT/sys/devices/platform/mock-usb/$bus_port"
	mkdir -p "$usb_dir/$bus_port:1.2" "$TESTROOT/sys/class/tty/ttyUSB$tty_index"
	printf '%s\n' "$vendor" >"$usb_dir/idVendor"
	printf '%s\n' "$product" >"$usb_dir/idProduct"
	[ -z "$serial" ] || printf '%s\n' "$serial" >"$usb_dir/serial"
	ln -s "$usb_dir/$bus_port:1.2" "$TESTROOT/sys/class/tty/ttyUSB$tty_index/device"
}

# One tty on an existing USB device, with its own interface number, so that the
# cache key (the USB interface path) differs per port exactly as it does on real
# hardware. `behaviour` is consumed by the mocked sms_tool below.
add_at_port() {
	bus_port="$1"; tty_index="$2"; interface="$3"; behaviour="$4"
	usb_dir="$TESTROOT/sys/devices/platform/mock-usb/$bus_port"
	mkdir -p "$usb_dir/$bus_port:$interface" "$TESTROOT/sys/class/tty/ttyUSB$tty_index"
	ln -s "$usb_dir/$bus_port:$interface" "$TESTROOT/sys/class/tty/ttyUSB$tty_index/device"
	printf '/dev/ttyUSB%s\t%s\n' "$tty_index" "$behaviour" >>"$TEST_AT_PORTS"
}

reset_at_ports() {
	: >"$TEST_AT_PORTS"
	: >"$TEST_AT_PROBES"
	rm -rf "$TEST_MODEM_STATE_DIR/at-ports"
}

reset_sysfs

# ---- tests ----

printf '%s\n' 'TEST service-start worker performs a full read-only rescan'
cat >"$MOCKBIN/modem-boot-command" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_STATE/boot-modem-calls"
EOF
chmod 0755 "$MOCKBIN/modem-boot-command"
: >"$STATE/boot-modem-calls"
APN_AUTOCONFIG_MODEM_BIN="$MOCKBIN/modem-boot-command" sh "$BOOT_WORKER" >/dev/null 2>&1 || \
	fail 'service-start worker failed'
grep -F -x -q rescan "$STATE/boot-modem-calls" || fail 'service-start worker did not run a full rescan'
grep -F -q "option autostart '1'" "$BASE/apn-autoconfig-modem/files/etc/config/apn-autoconfig-modem" || \
	fail 'modem inventory service is not enabled by default for live installation discovery'
grep -F -q '/etc/init.d/apn-autoconfig-modem restart' "$BASE/apn-autoconfig-modem/Makefile" || \
	fail 'live package installation does not start the inventory service'
! grep -F -q 'rm -rf /var/run/apn-autoconfig-modem /var/lock/apn-autoconfig-modem*' \
	"$BASE/apn-autoconfig-modem/Makefile" || \
	fail 'package removal still uses an unsafe wildcard to delete operation locks'
grep -F -q 'kill -0 "$${lock_pid}"' "$BASE/apn-autoconfig-modem/Makefile" || \
	fail 'package removal does not preserve a lock owned by a live operation'

printf '%s\n' 'TEST USB hotplug storms coalesce into one delayed inventory rescan'
reset_sysfs
add_qmi_modem 1-1.1 2c7c 0801 '' 9
: >"$TEST_UQMI_CALLS"
mv "$MOCKBIN/sleep" "$MOCKBIN/sleep.mock"
TEST_HOTPLUG_COALESCE_SECONDS=2
export TEST_HOTPLUG_COALESCE_SECONDS
ACTION=add APN_AUTOCONFIG_MODEM_BIN="$SCRIPT" sh "$HOTPLUG_SCRIPT"
ACTION=add APN_AUTOCONFIG_MODEM_BIN="$SCRIPT" sh "$HOTPLUG_SCRIPT"
# Leave enough margin for the two-second debounce plus a full inventory scan on
# a loaded CI runner. The production debounce value itself is unchanged.
/bin/sleep 5
mv "$MOCKBIN/sleep.mock" "$MOCKBIN/sleep"
TEST_HOTPLUG_COALESCE_SECONDS=0
export TEST_HOTPLUG_COALESCE_SECONDS
[ "$(grep -c -- '--get-imei' "$TEST_UQMI_CALLS")" -eq 1 ] || \
	fail 'duplicate USB hotplug events did not coalesce into one scan'

printf '%s\n' 'TEST inventory-json is empty when no modem is present'
reset_sysfs
out="$(sh "$SCRIPT" inventory-json)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["version"]=="v1"; assert d["modems"]==[]' "$out" \
	|| fail 'empty inventory did not return an empty modems array'

printf '%s\n' 'TEST a single QMI modem with a USB serial resolves the strongest evidence tier'
reset_sysfs
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0 wwan0
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 1, d
m = d["modems"][0]
assert m["evidence_tier"] == "usb-serial", m
assert m["modem_id"].startswith("usb-serial:1-1.2:"), m
assert m["control_device"] == "/dev/cdc-wdm0", m
assert m["data_device"] == "wwan0", m
assert m["protocol"] == "qmi", m
assert m["implementation_state"] == "stable", m
assert m["validation_state"] == "hardware", m
assert m["hardware_validated"] is True, m
assert m["owner_state"] == "none", m
assert m["ambiguous"] is False, m
' "$out" || fail 'single QMI modem record is wrong'

printf '%s\n' 'TEST a modem without a USB serial falls back to IMEI evidence when uqmi is available'
reset_sysfs
add_qmi_modem 1-1.3 2c7c 0801 '' 1
out="$(UQMI_IMEI=490154203237518 sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
m = d["modems"][0]
assert m["evidence_tier"] == "imei", m
assert m["modem_id"] == "imei:490154203237518", m
' "$out" || fail 'IMEI evidence tier was not used when no USB serial is present'

printf '%s\n' 'TEST QMI identity remains bounded when no external timeout command exists'
: >"$TEST_UQMI_CALLS"
bounded_start="$(date +%s)"
out="$(UQMI_HANG=1 APN_AUTOCONFIG_MODEM_TIMEOUT=missing-timeout sh "$SCRIPT" inventory-json)"
bounded_elapsed=$(( $(date +%s) - bounded_start ))
[ "$bounded_elapsed" -lt 5 ] || fail 'QMI identity probe hung without an external timeout command'
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["modems"][0]["evidence_tier"] == "weak-vidpid"' "$out" \
	|| fail 'timed-out QMI identity did not degrade to weak read-only inventory'

printf '%s\n' 'TEST uncertain ModemManager ownership prevents direct QMI identity access'
: >"$TEST_UQMI_CALLS"
out="$(MM_UNAVAILABLE=1 UQMI_IMEI=490154203237518 sh "$SCRIPT" inventory-json)"
[ ! -s "$TEST_UQMI_CALLS" ] || fail 'inventory opened QMI after ModemManager ownership discovery failed'
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["modems"][0]["evidence_tier"] == "weak-vidpid"' "$out" \
	|| fail 'uncertain ModemManager ownership did not degrade to weak inventory'

printf '%s\n' 'TEST inventory shares the APN QMI identity lock and never overlaps its control transaction'
: >"$TEST_UQMI_CALLS"
qmi_lock="${TEST_QMI_IDENTITY_LOCK_ROOT}.cdc-wdm1"
mkdir "$qmi_lock"
printf '%s\n' "$$" >"$qmi_lock/pid"
out="$(UQMI_IMEI=490154203237518 sh "$SCRIPT" inventory-json)"
rm -f "$qmi_lock/pid"
rmdir "$qmi_lock"
[ ! -s "$TEST_UQMI_CALLS" ] || fail 'inventory opened QMI while the APN identity adapter owned its lock'
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["modems"][0]["evidence_tier"] == "weak-vidpid"' "$out" \
	|| fail 'busy QMI identity lock did not degrade safely to weak read-only inventory'

printf '%s\n' 'TEST a modem with neither serial nor reachable identity falls back to weak-vidpid'
reset_sysfs
add_qmi_modem 1-1.4 2c7c 0801 '' 2
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
m = d["modems"][0]
assert m["evidence_tier"] == "weak-vidpid", m
assert m["modem_id"] == "weak-vidpid:1-1.4:2c7c:0801", m
assert m["capabilities"]["reset"] is False, m
' "$out" || fail 'weak-vidpid fallback is wrong'

printf '%s\n' 'TEST MBIM and AT-only devices are inventoried without claiming write capability'
reset_sysfs
add_mbim_modem 3-1.1 2cb7 0007 MBIMSERIAL 4 wwan4
add_at_modem 3-1.2 2cb7 01a2 ATSERIAL 8
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 2, d
by_protocol = {m["protocol"]: m for m in d["modems"]}
assert set(by_protocol) == {"mbim", "at"}, by_protocol
assert by_protocol["mbim"]["control_device"] == "/dev/cdc-wdm4", by_protocol
assert by_protocol["mbim"]["data_device"] == "wwan4", by_protocol
assert by_protocol["at"]["at_device"] == "/dev/ttyUSB8", by_protocol
assert not by_protocol["mbim"]["capabilities"]["reset"], by_protocol
assert not by_protocol["at"]["capabilities"]["reset"], by_protocol
# Maturity is about this implementation, evidence about the protocol: MBIM
# classification has a hardware record, AT-only has fixtures alone.
assert by_protocol["mbim"]["implementation_state"] == "stable", by_protocol
assert by_protocol["mbim"]["validation_state"] == "hardware", by_protocol
assert by_protocol["mbim"]["hardware_validated"] is True, by_protocol
assert by_protocol["at"]["implementation_state"] == "stable", by_protocol
assert by_protocol["at"]["validation_state"] == "synthetic", by_protocol
assert by_protocol["at"]["hardware_validated"] is False, by_protocol
' "$out" || fail 'inventory-only MBIM/AT classification is wrong'

printf '%s\n' 'TEST the board power-cycle follows the pinned modem, not its control protocol'
# The GPIO cuts power to the slot, so the capability belongs to the board and
# the physical modem. Gating it on QMI disabled the validated button path as
# soon as the same modem ran MBIM.
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
TEST_RESET_MODEM_ID='usb-serial:3-1.1:2cb7:0007:MBIMSERIAL'
export TEST_RESET_MODEM_ID
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
by_protocol = {m["protocol"]: m for m in json.loads(sys.argv[1])["modems"]}
assert by_protocol["mbim"]["capabilities"]["reset"] is True, by_protocol
assert by_protocol["at"]["capabilities"]["reset"] is False, by_protocol
' "$out" || fail 'a pinned MBIM modem lost the board power-cycle capability'
TEST_RESET_MODEM_ID='usb-serial:3-1.2:2cb7:01a2:ATSERIAL'
export TEST_RESET_MODEM_ID
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
by_protocol = {m["protocol"]: m for m in json.loads(sys.argv[1])["modems"]}
assert by_protocol["at"]["capabilities"]["reset"] is False, by_protocol
assert by_protocol["mbim"]["capabilities"]["reset"] is False, by_protocol
' "$out" || fail 'an AT-only modem advertised reset, or an unpinned MBIM modem kept it'
TEST_RESET_MODEM_ID=''
export TEST_RESET_MODEM_ID

printf '%s\n' 'TEST a QMI modem with multiple optional AT ports keeps its proven control binding'
reset_sysfs
add_qmi_modem 3-1.3 2c7c 0801 MULTIPORT 5
add_at_modem 3-1.3 2c7c 0801 MULTIPORT 1
add_at_modem 3-1.3 2c7c 0801 MULTIPORT 2
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["protocol"] == "qmi", m
assert m["control_device"] == "/dev/cdc-wdm5", m
assert m["ambiguous"] is False, m
assert m["owner_state"] == "none", m
assert not m["at_device"], m
' "$out" || fail 'optional AT ports incorrectly blocked a proven QMI control path'

printf '%s\n' 'TEST an AT-only modem with multiple ports is one unambiguous record'
# Reverses the pre-0.14.0 rule. Several tty nodes correlated to one proven USB
# device are one modem exposing several ports, not two candidate modems, and
# treating them as ambiguous made every ordinary multi-port modem unusable.
reset_sysfs
reset_at_ports
add_at_modem 3-1.4 2c7c 0801 ATMULTIPORT 1
add_at_modem 3-1.4 2c7c 0801 ATMULTIPORT 2
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 1, d
m = d["modems"][0]
assert m["protocol"] == "at", m
assert m["ambiguous"] is False, m
assert m["owner_state"] == "none", m
assert not m["at_device"], m
assert m["capabilities"]["at_identity"] is False, m
' "$out" || fail 'AT-only multi-port modem was not reduced to one unambiguous record'
[ ! -s "$TEST_AT_PROBES" ] || fail 'discovery probed an AT port'

printf '%s\n' 'TEST discovery never probes, however many ports are present'
reset_sysfs
reset_at_ports
add_at_modem 4-1.1 1234 5678 SWEEPME 20
add_at_port 4-1.1 21 1.3 dead
add_at_port 4-1.1 22 1.4 control
sh "$SCRIPT" inventory-json >/dev/null
sh "$SCRIPT" status-json --modem "usb-serial:4-1.1:1234:5678:SWEEPME" >/dev/null
[ ! -s "$TEST_AT_PROBES" ] || \
	fail "discovery or status probed an AT port: $(cat "$TEST_AT_PROBES")"

printf '%s\n' 'TEST at-port resolves by role, skipping ports that never answer'
reset_sysfs
reset_at_ports
add_at_modem 4-1.2 1234 5678 ROLEPROBE 30
printf '/dev/ttyUSB30\tdead\n' >>"$TEST_AT_PORTS"
add_at_port 4-1.2 31 1.3 atonly
add_at_port 4-1.2 32 1.4 atonly-silent
add_at_port 4-1.2 33 1.5 control
add_at_port 4-1.2 34 1.6 control
MODEM_ROLE="usb-serial:4-1.2:1234:5678:ROLEPROBE"
port="$(sh "$SCRIPT" at-port --modem "$MODEM_ROLE")" || fail 'at-port failed to resolve a control port'
[ "$port" = /dev/ttyUSB33 ] || fail "at-port selected $port instead of the lowest-indexed control port"
grep -q "/dev/ttyUSB31	AT+CGMM" "$TEST_AT_PROBES" || \
	fail 'the port that rejects the model query was not reached by the second phase'
grep -q "/dev/ttyUSB32	AT+CGMM" "$TEST_AT_PROBES" || \
	fail 'the port that answers OK without a model was not reached by the second phase'

printf '%s\n' 'TEST several responding ports on one device are redundancy, not ambiguity'
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["ambiguous"] is False, m
assert m["at_device"] == "/dev/ttyUSB33", m
assert m["capabilities"]["at_identity"] is True, m
' "$out" || fail 'a resolved multi-responder modem was not reported as usable'

printf '%s\n' 'TEST a cached selection is revalidated and no other port is touched'
: >"$TEST_AT_PROBES"
port="$(sh "$SCRIPT" at-port --modem "$MODEM_ROLE")" || fail 'cached at-port failed'
[ "$port" = /dev/ttyUSB33 ] || fail "cached resolution returned $port"
if awk -F'\t' '$1 != "/dev/ttyUSB33"' "$TEST_AT_PROBES" | grep -q .; then
	fail "a cached selection still swept other ports: $(cut -f1 "$TEST_AT_PROBES" | sort -u | tr '\n' ' ')"
fi
grep -q '/dev/ttyUSB33' "$TEST_AT_PROBES" || fail 'the cached port was not revalidated before reuse'

printf '%s\n' 'TEST a port recorded as dead is skipped when the selection has to be redone'
# Deleting only the selection forces a fresh sweep, which is the one path where
# the negative cache does any work. Asserting it through the selection cache
# proved nothing: that path short-circuits before a sweep can happen at all.
rm -f "$TEST_MODEM_STATE_DIR"/at-ports/selected.*
: >"$TEST_AT_PROBES"
port="$(sh "$SCRIPT" at-port --modem "$MODEM_ROLE")" || fail 'resweep after losing the selection failed'
[ "$port" = /dev/ttyUSB33 ] || fail "resweep selected $port instead of /dev/ttyUSB33"
if grep -q '/dev/ttyUSB30' "$TEST_AT_PROBES"; then
	fail 'a port cached as dead was swept again'
fi
grep -q '/dev/ttyUSB31' "$TEST_AT_PROBES" || \
	fail 'the resweep skipped a port that had answered, which is not cached as dead'

printf '%s\n' 'TEST a cached port that stopped answering is discarded and resolution runs again'
sed -i.bak 's|^/dev/ttyUSB33	control$|/dev/ttyUSB33	dead|' "$TEST_AT_PORTS"
rm -f "$TEST_AT_PORTS.bak"
port="$(sh "$SCRIPT" at-port --modem "$MODEM_ROLE")" || fail 'resolution did not recover from a stale cache'
[ "$port" = /dev/ttyUSB34 ] || fail "stale cache recovery selected $port instead of /dev/ttyUSB34"

printf '%s\n' 'TEST at-identity emits the v1 identity contract over AT'
reset_sysfs
reset_at_ports
add_at_modem 7-1.1 0e8d 7127 '' 50
printf '/dev/ttyUSB50\tcontrol\n' >>"$TEST_AT_PORTS"
MODEM_ID_AT="weak-vidpid:7-1.1:0e8d:7127"
sh "$SCRIPT" at-identity --modem "$MODEM_ID_AT" >"$STATE/at-identity" || fail 'at-identity failed'
awk -F'\t' '
	NR == 1 { if ($0 != "v1") { print "bad version line: " $0 > "/dev/stderr"; exit 1 } next }
	{ seen[$1] = $2 }
	END {
		required = "sim_index modem_index iccid imsi eid operator_id operator_name gid1 gid2 " \
			"modem_state registration_state roaming serving_operator_id serving_operator_name " \
			"access_technologies signal_quality"
		n = split(required, want, " ")
		for (i = 1; i <= n; i++)
			if (!(want[i] in seen)) { print "missing field: " want[i] > "/dev/stderr"; exit 1 }
		if (seen["iccid"] != "89492031246010483050") { print "iccid: " seen["iccid"] > "/dev/stderr"; exit 1 }
		if (seen["imsi"] != "262023103971566") { print "imsi: " seen["imsi"] > "/dev/stderr"; exit 1 }
		if (seen["operator_id"] != "") { print "operator_id must stay empty" > "/dev/stderr"; exit 1 }
		if (seen["serving_operator_id"] != "26202") { print "serving: " seen["serving_operator_id"] > "/dev/stderr"; exit 1 }
		if (seen["registration_state"] != "home") { print "registration: " seen["registration_state"] > "/dev/stderr"; exit 1 }
		if (seen["roaming"] != "false") { print "roaming: " seen["roaming"] > "/dev/stderr"; exit 1 }
		if (seen["access_technologies"] != "lte,5gnr") { print "act: " seen["access_technologies"] > "/dev/stderr"; exit 1 }
		if (seen["modem_state"] != "enabled") { print "modem_state: " seen["modem_state"] > "/dev/stderr"; exit 1 }
		if (seen["signal_quality"] !~ /^[0-9]+$/) { print "signal: " seen["signal_quality"] > "/dev/stderr"; exit 1 }
	}
' "$STATE/at-identity" || fail 'the v1 identity contract was not satisfied'

printf '%s\n' 'TEST CESQ RSRP outranks CSQ, and the NR extension fields do not break the parse'
# 49 maps to -91 dBm on the documented -120..-80 scale, which is 73%. Reading
# CSQ instead would have given -89 dBm on a different scale and 35%, so this
# also proves which of the two sources won.
signal="$(awk -F'\t' '$1 == "signal_quality" { print $2 }' "$STATE/at-identity")"
[ "$signal" = 73 ] || fail "signal_quality was $signal, not the CESQ-derived 73"

printf '%s\n' 'TEST a serial-less modem is upgraded from weak-vidpid to the imei tier'
# The record could only ever have been weak before: this modem exposes no USB
# serial and no QMI/MBIM control channel, so the one path to a strong tier runs
# through an AT-supplied IMEI. Discovery still does not probe for it — the read
# above cached it, and discovery reads the cache.
: >"$TEST_AT_PROBES"
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["modem_id"] == "imei:016177002734885", m
assert m["evidence_tier"] == "imei", m
' "$out" || fail 'the modem was not upgraded to the imei tier'
[ ! -s "$TEST_AT_PROBES" ] || fail 'the tier upgrade probed instead of reading the cache'
MODEM_ID_AT="imei:016177002734885"

printf '%s\n' 'TEST the port selection survives the identity change that renames the record'
# The caches are keyed by physical port and VID:PID rather than by modem_id, so
# the upgrade cannot orphan the entries it was made from.
: >"$TEST_AT_PROBES"
port="$(sh "$SCRIPT" at-port --modem "$MODEM_ID_AT")" || fail 'at-port failed after the tier upgrade'
[ "$port" = /dev/ttyUSB50 ] || fail "at-port returned $port after the upgrade"
if awk -F'\t' '$1 != "/dev/ttyUSB50"' "$TEST_AT_PROBES" | grep -q .; then
	fail 'the renamed record lost its cached selection and swept again'
fi

printf '%s\n' 'TEST an unknown CESQ RSRP falls back to CSQ rather than reporting no signal'
TEST_AT_CESQ="99,99,255,255,255,255,255,255,255" \
	sh "$SCRIPT" at-identity --modem "$MODEM_ID_AT" >"$STATE/at-identity-csq" || fail 'fallback identity failed'
signal="$(awk -F'\t' '$1 == "signal_quality" { print $2 }' "$STATE/at-identity-csq")"
[ "$signal" = 35 ] || fail "CSQ fallback produced $signal instead of 35"

printf '%s\n' 'TEST registration stat 6 is a registered state, and the ICCID ladder reaches the vendor spelling'
reset_sysfs
reset_at_ports
add_at_modem 7-1.2 2c7c 0125 '' 51
printf '/dev/ttyUSB51\tcontrol-legacy\n' >>"$TEST_AT_PORTS"
sh "$SCRIPT" at-identity --modem "weak-vidpid:7-1.2:2c7c:0125" >"$STATE/at-identity-legacy" || \
	fail 'at-identity failed against the legacy modem'
awk -F'\t' '
	$1 == "registration_state" && $2 != "home" { print "stat 6 read as " $2 > "/dev/stderr"; exit 1 }
	$1 == "roaming" && $2 != "false" { print "roaming: " $2 > "/dev/stderr"; exit 1 }
	$1 == "iccid" && $2 != "89492031246010483050" { print "iccid: " $2 > "/dev/stderr"; exit 1 }
	$1 == "access_technologies" && $2 != "lte" { print "act: " $2 > "/dev/stderr"; exit 1 }
	$1 == "signal_quality" && $2 != "35" { print "signal: " $2 > "/dev/stderr"; exit 1 }
' "$STATE/at-identity-legacy" || fail 'the legacy modem was misread'
grep -q "/dev/ttyUSB51	AT+CCID" "$TEST_AT_PROBES" || fail 'the standard ICCID spelling was not tried first'
grep -q "/dev/ttyUSB51	AT+QCCID" "$TEST_AT_PROBES" || fail 'the ladder did not advance to the vendor spelling'

printf '%s\n' 'TEST identity evidence reaches the inventory record without a further probe'
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["manufacturer"] == "Quectel", m
assert m["model"] == "EC25-E", m
assert m["firmware_revision"] == "EC25EFAR06A11M4G", m
' "$out" || fail 'identity evidence did not reach the inventory record'
: >"$TEST_AT_PROBES"
sh "$SCRIPT" inventory-json >/dev/null
[ ! -s "$TEST_AT_PROBES" ] || fail 'displaying identity evidence caused a probe'

printf '%s\n' 'TEST a modem with no readable SIM fails rather than reporting a partial identity'
# The port resolves and answers every hardware query, so the failure has to come
# from the identity floor rather than from resolution. An earlier version of
# this test used a port that never resolved at all, which asserted nothing about
# the floor and passed with the floor removed.
reset_sysfs
reset_at_ports
add_at_modem 7-1.3 1234 9999 '' 52
printf '/dev/ttyUSB52\tcontrol-nosim\n' >>"$TEST_AT_PORTS"
sh "$SCRIPT" at-port --modem "weak-vidpid:7-1.3:1234:9999" >/dev/null || \
	fail 'the no-SIM port should still resolve as a control port'
noiccid=0
sh "$SCRIPT" at-identity --modem "weak-vidpid:7-1.3:1234:9999" >/dev/null 2>&1 || noiccid=$?
[ "$noiccid" -eq 3 ] || fail "a modem with no SIM identity exited $noiccid instead of the retryable class 3"

printf '%s\n' 'TEST the watchdog bounds a silent port when no external timeout exists'
# Not an exotic-image fallback: the reference router has no timeout executable
# at all, so this is the branch that actually runs there. The suite's own sleep
# is a no-op, so the watchdog needs the real one to be tested honestly.
reset_sysfs
reset_at_ports
add_at_modem 4-1.3 1234 5678 WATCHDOG 35
printf '/dev/ttyUSB35\tdead\n' >>"$TEST_AT_PORTS"
add_at_port 4-1.3 36 1.3 control
# stdout and stderr are kept apart. Merging them made this assertion depend on
# whether the shell announces the killed probe as "Terminated" — which some do
# and some do not, so the test passed on the author's machine and failed in CI
# on a result that was in fact correct. The requirement is that the *result*
# channel carries the port and nothing else; stderr is only reported here,
# because suppressing a shell's job-control notice is not portable enough to
# gate a release on.
APN_AUTOCONFIG_MODEM_TIMEOUT="$TESTROOT/absent-timeout" \
APN_AUTOCONFIG_MODEM_SLEEP="$(command -v /bin/sleep || command -v /usr/bin/sleep)" \
	sh "$SCRIPT" at-port --modem "usb-serial:4-1.3:1234:5678:WATCHDOG" \
	>"$STATE/watchdog-port" 2>"$STATE/watchdog-err" || \
	fail "the watchdog path failed to resolve: $(cat "$STATE/watchdog-err")"
[ "$(cat "$STATE/watchdog-port")" = /dev/ttyUSB36 ] || \
	fail "watchdog path selected '$(cat "$STATE/watchdog-port")' instead of /dev/ttyUSB36 (stderr: $(cat "$STATE/watchdog-err"))"
grep -q '/dev/ttyUSB35' "$TEST_AT_PROBES" || fail 'the watchdog path never reached the silent port'
ls /tmp/apn-autoconfig-modem.*.bounded-timeout >/dev/null 2>&1 && \
	fail 'the watchdog left its timeout marker behind'

printf '%s\n' 'TEST a different modem in the same USB socket does not inherit the previous one'
reset_sysfs
: >"$TEST_AT_PORTS"; : >"$TEST_AT_PROBES"
rm -rf "$TEST_MODEM_STATE_DIR/at-ports"
add_at_modem 10-1.1 1111 1111 '' 70
printf '/dev/ttyUSB70\tdead\n' >>"$TEST_AT_PORTS"
add_at_port 10-1.1 71 1.3 control
port="$(sh "$SCRIPT" at-port --modem "weak-vidpid:10-1.1:1111:1111")" || fail 'first modem did not resolve'
[ "$port" = /dev/ttyUSB71 ] || fail "first modem resolved to $port"

# Swap in another model on the same physical port, whose control channel happens
# to sit on the interface the previous modem's dead port occupied. Keying the
# verdict cache by port alone would make that channel permanently invisible, and
# nothing would look broken — the modem would simply never resolve.
reset_sysfs
: >"$TEST_AT_PORTS"; : >"$TEST_AT_PROBES"
add_at_modem 10-1.1 3333 4444 '' 72
printf '/dev/ttyUSB72\tcontrol\n' >>"$TEST_AT_PORTS"
port="$(sh "$SCRIPT" at-port --modem "weak-vidpid:10-1.1:3333:4444")" || \
	fail 'the replacement modem inherited a dead-port verdict from its predecessor'
[ "$port" = /dev/ttyUSB72 ] || fail "the replacement modem resolved to $port"

printf '%s\n' 'TEST the resolver refuses a port the QMI adapter is holding, rather than proceeding'
# The other half of the shared namespace, asserted from this side. A reader that
# waits, fails to acquire and then reads anyway would corrupt both its own reply
# stream and the holder's, so failing to acquire has to be a refusal.
reset_sysfs
reset_at_ports
add_at_modem 9-1.1 1234 5678 CONTENDED 55
printf '/dev/ttyUSB55\tcontrol\n' >>"$TEST_AT_PORTS"
held_lock="$TEST_AT_PORT_LOCK_ROOT.ttyUSB55"
mkdir -p "$(dirname "$held_lock")"
printf '%s\n' "$$" >"$held_lock"
contended=0
sh "$SCRIPT" at-port --modem "usb-serial:9-1.1:1234:5678:CONTENDED" >/dev/null 2>&1 || contended=$?
[ "$contended" -ne 0 ] || fail 'the resolver used a port that another package had locked'
[ ! -s "$TEST_AT_PROBES" ] || fail 'the resolver wrote to a locked port'
rm -f "$held_lock"
port="$(sh "$SCRIPT" at-port --modem "usb-serial:9-1.1:1234:5678:CONTENDED")" || \
	fail 'the resolver did not recover once the shared lock was released'
[ "$port" = /dev/ttyUSB55 ] || fail "recovery returned $port"
[ ! -e "$held_lock" ] || fail 'the resolver left the shared port lock behind'

printf '%s\n' 'TEST a probe never reaches a port belonging to another modem'
# The target modem deliberately owns the *higher* tty index. With correlation
# working, its own port is the only one probed; without it, the neighbour's
# lower-numbered port would be swept first and would satisfy the resolution, so
# this ordering is what makes the assertion mean anything.
reset_sysfs
reset_at_ports
add_at_modem 5-1.1 3333 4444 NEIGHBOUR 40
printf '/dev/ttyUSB40\tcontrol\n' >>"$TEST_AT_PORTS"
add_at_modem 5-1.2 1111 2222 FIRSTMODEM 41
printf '/dev/ttyUSB41\tcontrol\n' >>"$TEST_AT_PORTS"
port="$(sh "$SCRIPT" at-port --modem "usb-serial:5-1.2:1111:2222:FIRSTMODEM")" || \
	fail 'at-port failed with two modems present'
[ "$port" = /dev/ttyUSB41 ] || fail "at-port returned $port, which is not this modem's own port"
if grep -q '/dev/ttyUSB40' "$TEST_AT_PROBES"; then
	fail "a probe for one modem reached the other modem's port"
fi

printf '%s\n' 'TEST a port cached while unowned grants nothing once ModemManager claims the modem'
# The reference router publishes a freshly attached modem in ModemManager only
# after it has finished probing every port, so a scan at attach time sees the
# modem unowned and a later one sees it owned. That makes unowned-then-owned the
# normal sequence rather than a race, and a selection cached in the first window
# must not survive as a licence into the second.
reset_sysfs
reset_at_ports
add_qmi_modem 6-1.1 2c7c 0801 MMOWNED 7 wwan7
add_at_port 6-1.1 45 1.2 control
MM_OWNED="usb-serial:6-1.1:2c7c:0801:MMOWNED"
port="$(sh "$SCRIPT" at-port --modem "$MM_OWNED")" || fail 'at-port failed while the modem was unowned'
[ "$port" = /dev/ttyUSB45 ] || fail "unowned resolution returned $port"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["capabilities"]["at_identity"] is True, m
' "$(sh "$SCRIPT" inventory-json)" || fail 'a resolved unowned modem did not report at_identity'

MM_MODEM_INDEX=0
MM_DEVICE="$TESTROOT/sys/devices/platform/mock-usb/6-1.1"
MM_PHYSDEV="$MM_DEVICE"
export MM_MODEM_INDEX MM_DEVICE MM_PHYSDEV
: >"$TEST_AT_PROBES"
mm_refused=0
sh "$SCRIPT" at-port --modem "$MM_OWNED" >/dev/null 2>&1 || mm_refused=$?
[ "$mm_refused" -eq 4 ] || fail "AT access under ModemManager exited $mm_refused instead of the blocked class 4"
[ ! -s "$TEST_AT_PROBES" ] || fail 'a ModemManager-owned modem was probed anyway'
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["owner_state"] == "modemmanager", m
assert m["capabilities"]["at_identity"] is False, m
' "$(sh "$SCRIPT" inventory-json)" || \
	fail 'a cached selection kept at_identity true after ModemManager took the modem'
unset MM_MODEM_INDEX MM_DEVICE MM_PHYSDEV

printf '%s\n' 'TEST two distinct physically present modems are both reported, not merged'
reset_sysfs
add_qmi_modem 1-1.2 2c7c 0801 SERIALA 0
add_qmi_modem 1-1.5 2c7c 0801 SERIALB 1
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 2, d
ids = sorted(m["modem_id"] for m in d["modems"])
assert ids == sorted(["usb-serial:1-1.2:2c7c:0801:SERIALA", "usb-serial:1-1.5:2c7c:0801:SERIALB"]), ids
assert all(m["ambiguous"] is False for m in d["modems"]), d
' "$out" || fail 'two distinct modems were not both reported without ambiguity'

printf '%s\n' 'TEST equal weak identities are ambiguous and cannot bind a target'
reset_sysfs
reset_network_config
add_qmi_modem 1-1.2 2c7c 0801 '' 0
add_qmi_modem 1-1.5 2c7c 0801 '' 1
add_network_section weakone qmi /dev/cdc-wdm0
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 2, d
assert all(m["ambiguous"] for m in d["modems"]), d
assert all(m["owner_state"] == "conflicting" for m in d["modems"]), d
assert all(not m["netifd_interface"] for m in d["modems"]), d
' "$out" || fail 'equal weak modem identities did not fail closed'
if sh "$SCRIPT" resolve --interface weakone >/dev/null 2>&1; then
	fail 'resolve accepted a modem whose identity is only one of multiple equal weak candidates'
fi

printf '%s\n' 'TEST a netifd qmi section bound to the control device yields owner_state netifd-direct'
reset_sysfs
reset_network_config
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0 wwan0
add_network_section cellqmi qmi /dev/cdc-wdm0
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
m = d["modems"][0]
assert m["owner_state"] == "netifd-direct", m
assert m["netifd_interface"] == "cellqmi", m
' "$out" || fail 'netifd-direct owner state was not derived from the bound network section'

printf '%s\n' 'TEST two netifd sections claiming one modem are conflicting rather than first-match wins'
add_network_section cellqmi2 qmi /dev/cdc-wdm0
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["ambiguous"] is True, m
assert m["owner_state"] == "conflicting", m
assert not m["netifd_interface"], m
' "$out" || fail 'multiple netifd claims did not fail closed'
reset_network_config
add_network_section cellqmi qmi /dev/cdc-wdm0

printf '%s\n' 'TEST resolve prints the modem_id bound to an interface and fails closed otherwise'
out="$(sh "$SCRIPT" resolve --interface cellqmi)"
[ "$out" = "usb-serial:1-1.2:2c7c:0801:RM520SERIAL01" ] || fail "resolve returned unexpected modem_id: $out"
if sh "$SCRIPT" resolve --interface wwan >/dev/null 2>&1; then
	fail 'resolve should fail closed for an interface with no bound modem'
else
	[ "$?" -eq 3 ] || :
fi

printf '%s\n' 'TEST ModemManager-owned modem with no direct netifd binding is owner_state modemmanager'
reset_sysfs
reset_network_config
add_qmi_modem 2-1.1 2c7c 0125 '' 3
: >"$TEST_UQMI_CALLS"
out="$(MM_MODEM_INDEX=0 MM_DEVICE=cdc-wdm3 MM_PHYSDEV="$TESTROOT/sys/devices/platform/mock-usb/2-1.1" MM_IMEI=490154203237999 \
	sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 1, d
m = d["modems"][0]
assert m["owner_state"] == "modemmanager", m
assert m["modem_id"] == "imei:490154203237999", m
' "$out" || fail 'ModemManager-only ownership was not detected correctly'
[ ! -s "$TEST_UQMI_CALLS" ] || fail 'inventory issued a direct uqmi transaction against a ModemManager-owned modem'

printf '%s\n' 'TEST physical-root ModemManager and netifd paths correlate like the WH3000 runtime'
reset_sysfs
reset_network_config
add_qmi_modem 2-1.4 2c7c 0801 '' 0 wwan0
printf "network.wwan=interface\nnetwork.wwan.proto='modemmanager'\n" >>"$TEST_NETWORK_SECTIONS"
printf '%s\tproto\t%s\n' wwan modemmanager >>"$TEST_NETWORK_OPTIONS"
printf '%s\tdevice\t%s\n' wwan "$TESTROOT/sys/devices/platform/mock-usb/2-1.4" >>"$TEST_NETWORK_OPTIONS"
: >"$TEST_UQMI_CALLS"
out="$(MM_MODEM_INDEX=0 \
	MM_DEVICE="$TESTROOT/sys/devices/platform/mock-usb/2-1.4" \
	MM_PHYSDEV="$TESTROOT/sys/devices/platform/mock-usb/2-1.4" \
	MM_IMEI=490154203237999 sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 1, d
m = d["modems"][0]
assert m["modem_id"] == "imei:490154203237999", m
assert m["protocol"] == "qmi", m
assert m["control_device"] == "/dev/cdc-wdm0", m
assert m["data_device"] == "wwan0", m
assert m["netifd_interface"] == "wwan", m
assert m["owner_state"] == "modemmanager", m
' "$out" || fail 'physical USB device-root in netifd device did not merge into one bound modem record'
[ ! -s "$TEST_UQMI_CALLS" ] || fail 'physical-root ModemManager ownership allowed a direct uqmi identity probe'
[ "$(MM_MODEM_INDEX=0 MM_DEVICE="$TESTROOT/sys/devices/platform/mock-usb/2-1.4" \
	MM_PHYSDEV="$TESTROOT/sys/devices/platform/mock-usb/2-1.4" MM_IMEI=490154203237999 \
	sh "$SCRIPT" resolve --interface wwan)" = imei:490154203237999 ] || \
	fail 'physical-root netifd devpath did not resolve the ModemManager-owned modem'

printf '%s\n' 'TEST a modemmanager section with no live ModemManager is owner_state none, not netifd-direct'
# The same modem and the same `wwan` binding as the test above, with
# ModemManager stopped — the state the reference router was left in while the
# AT transport was exercised. `proto=modemmanager` delegates the session to a
# daemon that is no longer running, so `qmi.sh` and friends hold nothing and
# nothing owns this modem. Reporting netifd-direct here claimed a direct netifd
# session that does not exist, and since 0.14.0 that name also carries an
# access consequence. Everything else the binding is used for must survive.
MM_STOPPED_MODEM=imei:490154203237999
out="$(UQMI_IMEI=490154203237999 sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert len(d["modems"]) == 1, d
m = d["modems"][0]
assert m["owner_state"] == "none", m
assert m["netifd_interface"] == "wwan", m
' "$out" || fail 'a modemmanager section without ModemManager was reported as a direct netifd session'
# The section is still a binding for every purpose other than ownership: it
# still resolves, and it still blocks provisioning a second section for it.
[ "$(UQMI_IMEI=490154203237999 sh "$SCRIPT" resolve --interface wwan)" = "$MM_STOPPED_MODEM" ] || \
	fail 'the bound section stopped resolving once its owner state became none'
plan_status=0
plan_out="$(UQMI_IMEI=490154203237999 sh "$SCRIPT" provision-plan --modem "$MM_STOPPED_MODEM" 2>/dev/null)" || plan_status=$?
[ "$plan_status" -eq 4 ] || \
	fail "provision-plan exited $plan_status for an already-bound modem instead of the blocked class 4"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["reason"] == "already_configured", d
assert d["can_provision"] is False, d
' "$plan_out" || fail 'a modem bound to a stopped-ModemManager section was offered for provisioning'

printf '%s\n' 'TEST a netifd section that does hold the session is still netifd-direct'
# The rule above must not swallow the ordinary case: same modem, same binding,
# proto=qmi instead, where netifd genuinely does hold the control device.
reset_network_config
add_network_section cellqmi qmi /dev/cdc-wdm0
out="$(UQMI_IMEI=490154203237999 sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["owner_state"] == "netifd-direct", m
assert m["netifd_interface"] == "cellqmi", m
' "$out" || fail 'a direct netifd protocol lost its netifd-direct owner state'

printf '%s\n' 'TEST ModemManager and a direct netifd protocol both claiming a modem is conflicting'
reset_network_config
add_network_section celldirect qmi /dev/cdc-wdm3
out="$(MM_MODEM_INDEX=0 MM_DEVICE=cdc-wdm3 MM_PHYSDEV="$TESTROOT/sys/devices/platform/mock-usb/2-1.1" MM_IMEI=490154203237999 \
	sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
m = d["modems"][0]
assert m["owner_state"] == "conflicting", m
' "$out" || fail 'dual ModemManager/netifd ownership was not classified as conflicting'
reset_network_config

printf '%s\n' 'TEST status-json reports not_found for an absent modem_id and exits retryable'
reset_sysfs
if out="$(sh "$SCRIPT" status-json --modem imei:doesnotexist)"; then
	fail 'status-json should fail for an absent modem'
else
	status=$?
	[ "$status" -eq 3 ] || fail "status-json for an absent modem returned exit $status, expected 3"
fi
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["error"]=="not_found"' "$out" \
	|| fail 'status-json not_found body is malformed'

printf '%s\n' 'TEST reset is refused without an installed board integration'
reset_sysfs
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0 wwan0
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID
rm -f "$HARDWARE_MARKER"
if sh "$SCRIPT" reset --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01 >/dev/null 2>&1; then
	fail 'reset should require a board integration marker'
else
	[ "$?" -eq 4 ] || fail 'reset without board integration did not use exit code 4'
fi

printf '%s\n' 'TEST reset is unavailable until a strong modem identity is explicitly pinned'
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
TEST_RESET_MODEM_ID=''
export TEST_RESET_MODEM_ID
out="$(sh "$SCRIPT" inventory-json)"
python3 -c 'import json,sys; m=json.loads(sys.argv[1])["modems"][0]; assert m["capabilities"]["reset"] is False, m' "$out" \
	|| fail 'an unpinned modem advertised reset capability'
if sh "$SCRIPT" reset --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01 >/dev/null 2>&1; then
	fail 'reset accepted an unpinned modem identity'
fi
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID
printf '%s\n' 'unexpected-integration-marker' >"$HARDWARE_MARKER"
if sh "$SCRIPT" reset --modem "$TEST_RESET_MODEM_ID" >/dev/null 2>&1; then
	fail 'reset accepted an unrecognized board integration marker'
fi

printf '%s\n' 'TEST reset power-cycles the GPIO, waits for re-enumeration and restores the interface'
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
: >"$TEST_EVENTS"
reset_network_config
add_network_section cellqmi qmi /dev/cdc-wdm0
sh "$SCRIPT" reset --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01 \
	|| fail 'reset with board integration and a present modem should succeed'
[ "$(cat "$GPIO")" = 0 ] || fail 'GPIO was not restored to the powered-on value after reset'
grep -F -x -q 'down cellqmi' "$TEST_EVENTS" || fail 'reset did not stop the bound interface before power-cycling'
grep -F -x -q 'up cellqmi' "$TEST_EVENTS" || fail 'reset did not restore the bound interface after success'
[ ! -d "${TEST_MODEM_LOCK_ROOT}.usb-serial_1-1.2_2c7c_0801_RM520SERIAL01" ] \
	|| fail 'per-modem lock was not released after reset'

printf '%s\n' 'TEST reset restarts its own modem interface, not whichever one the scan ended on'
# The third and worst instance of the same clobbering: reset_cmd held the bound
# interface in `netifd_interface`, a name scan_inventory reassigns per record,
# and both waits call that scan in this shell. With one modem the clobbered
# value equals the target and nothing looks wrong; with two, the reset can bring
# up somebody else's interface.
reset_sysfs
reset_at_ports
reset_network_config
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
add_qmi_modem 14-1.1 2c7c 0801 IFTARGET 4 wwan4
add_qmi_modem 14-1.2 2c7c 0801 ZIFOTHER 5 wwan5
add_network_section celltarget qmi /dev/cdc-wdm4
add_network_section zcellother qmi /dev/cdc-wdm5
TEST_RESET_MODEM_ID='usb-serial:14-1.1:2c7c:0801:IFTARGET'
export TEST_RESET_MODEM_ID
: >"$TEST_EVENTS"
sh "$SCRIPT" reset --modem "$TEST_RESET_MODEM_ID" >/dev/null 2>&1 || \
	fail 'the two-modem GPIO reset failed'
grep -F -x -q 'down celltarget' "$TEST_EVENTS" || fail 'reset stopped the wrong interface'
grep -F -x -q 'up celltarget' "$TEST_EVENTS" || fail 'reset did not restore its own interface'
if grep -F -x -q 'up zcellother' "$TEST_EVENTS" || grep -F -x -q 'down zcellother' "$TEST_EVENTS"; then
	fail 'reset touched a neighbouring modem interface'
fi
reset_network_config
reset_sysfs
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0 wwan0
add_network_section cellqmi qmi /dev/cdc-wdm0
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID

printf '%s\n' 'TEST reset waits for the original ModemManager owner before restoring netifd'
: >"$TEST_EVENTS"
rm -f "$STATE/ifdown-seen" "$STATE/mm-owner-scan-count" "$STATE/mm-owner-ready" "$STATE/up-before-owner"
reset_network_config
add_network_section wwan modemmanager "$TESTROOT/sys/devices/platform/mock-usb/1-1.2"
MM_DELAY_AFTER_IFDOWN=1 MM_MODEM_INDEX=0 MM_DEVICE=cdc-wdm0 \
	MM_PHYSDEV="$TESTROOT/sys/devices/platform/mock-usb/1-1.2" MM_IMEI=490154203237999 \
	sh "$SCRIPT" reset --modem "$TEST_RESET_MODEM_ID" || \
	fail 'reset did not wait for ModemManager to reclaim the modem'
[ "$(cat "$STATE/mm-owner-scan-count")" -eq 3 ] || fail 'reset did not poll until ModemManager returned'
[ ! -e "$STATE/up-before-owner" ] || fail 'reset restored netifd before ModemManager reclaimed the modem'
grep -F -x -q 'up wwan' "$TEST_EVENTS" || fail 'reset did not restore ModemManager netifd after owner readiness'

printf '%s\n' 'TEST interruption while GPIO is off restores power, interface and lock state'
reset_network_config
add_network_section cellqmi qmi /dev/cdc-wdm0
mv "$MOCKBIN/sleep" "$MOCKBIN/sleep.mock"
TEST_MODEM_POWER_OFF_SECONDS=5
export TEST_MODEM_POWER_OFF_SECONDS
: >"$TEST_EVENTS"
sh "$SCRIPT" reset --modem "$TEST_RESET_MODEM_ID" >/dev/null 2>&1 &
reset_pid=$!
signal_wait=50
while [ "$(cat "$GPIO")" != 1 ] && [ "$signal_wait" -gt 0 ]; do
	/bin/sleep 0.1
	signal_wait=$((signal_wait - 1))
done
[ "$(cat "$GPIO")" = 1 ] || fail 'signal test never observed the powered-off GPIO state'
transitioning_out="$(sh "$SCRIPT" inventory-json)"
python3 -c 'import json,sys; m=json.loads(sys.argv[1])["modems"][0]; assert m["owner_state"] == "transitioning", m' "$transitioning_out" \
	|| fail 'a synchronous reset lock was not exposed as transitioning inventory state'
kill -TERM "$reset_pid"
reset_status=0
wait "$reset_pid" || reset_status=$?
mv "$MOCKBIN/sleep.mock" "$MOCKBIN/sleep"
TEST_MODEM_POWER_OFF_SECONDS=1
export TEST_MODEM_POWER_OFF_SECONDS
[ "$reset_status" -eq 143 ] || fail "interrupted reset exited $reset_status instead of 143"
[ "$(cat "$GPIO")" = 0 ] || fail 'interrupted reset left modem power off'
grep -F -x -q 'up cellqmi' "$TEST_EVENTS" || fail 'interrupted reset did not restart the selected interface'
[ ! -e "${TEST_MODEM_LOCK_ROOT}.usb-serial_1-1.2_2c7c_0801_RM520SERIAL01" ] || \
	fail 'interrupted reset left the per-modem lock behind'

printf '%s\n' 'TEST a ModemManager-owned modem shows the model ModemManager knows, without any AT'
# The page put the model at the top of the card and it read "Unidentified" for a
# perfectly ordinary modem, because those fields were only ever filled by an AT
# identity read — which is refused on a modem ModemManager owns. The daemon
# already knows what it is holding, so the record uses its answer.
reset_sysfs
reset_at_ports
reset_network_config
add_qmi_modem 15-1.1 2c7c 0801 MMKNOWN 3 wwan3
add_at_port 15-1.1 90 1.5 control
MM_MODEM_INDEX=0
MM_DEVICE="$TESTROOT/sys/devices/platform/mock-usb/15-1.1"
MM_PHYSDEV="$MM_DEVICE"
MM_MANUFACTURER="Quectel"
MM_MODEL="RM520N-GL"
MM_REVISION="RM520NGLAAR03A01M4G"
export MM_MODEM_INDEX MM_DEVICE MM_PHYSDEV MM_MANUFACTURER MM_MODEL MM_REVISION
: >"$TEST_AT_PROBES"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["owner_state"] == "modemmanager", m
assert m["manufacturer"] == "Quectel", m
assert m["model"] == "RM520N-GL", m
assert m["firmware_revision"] == "RM520NGLAAR03A01M4G", m
' "$(sh "$SCRIPT" inventory-json)" || fail 'an owned modem did not show the model ModemManager reports'
[ ! -s "$TEST_AT_PROBES" ] || fail 'the record was filled by probing a modem ModemManager owns'

printf '%s\n' 'TEST ModemManager placeholders are not shown as if they were values'
# mmcli prints "--" for what it does not know, which is not a model name.
MM_MODEL='--' MM_REVISION='--' python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["manufacturer"] == "Quectel", m
assert m["model"] == "", m
assert m["firmware_revision"] == "", m
' "$(MM_MODEL='--' MM_REVISION='--' sh "$SCRIPT" inventory-json)" || \
	fail 'a ModemManager placeholder was presented as a model'
unset MM_MODEM_INDEX MM_DEVICE MM_PHYSDEV MM_MANUFACTURER MM_MODEL MM_REVISION

printf '%s\n' 'TEST the quirk table answers only what it was told, and the shipped one is empty'
# Exercised by sourcing rather than through a command, because 0.14.0 has no
# vendor-specific capability to hang on it. Adding a public verb with no caller
# is the same mistake the engine-facing AT adapter was deferred to avoid.
quirk_fixture="$STATE/quirks"
cat >"$quirk_fixture" <<'QUIRKS'
# comment lines are ignored
Fibocom Wireless Inc.	FM350-GL	*	example_capability	general
Fibocom Wireless Inc.	FM350-GL	81600.0000.00.29.21.27	example_capability	firmware-specific
Quectel	EC25-E	*	example_capability	quectel
Fibocom Wireless Inc.	FM350-GL	*	truncated_capability
QUIRKS
# `.` inherits the caller's positional parameters and the script ends in
# `main "$@"`, so the probe has to clear them before sourcing or it would
# dispatch a command instead of just defining functions. Arguments are held in
# named variables rather than re-split, because one of them contains spaces.
cat >"$STATE/quirk-probe" <<'PROBE'
#!/bin/sh
probe_table="$1"; probe_mfr="$2"; probe_model="$3"; probe_fw="$4"; probe_key="$5"
set --
. "$QUIRK_SCRIPT" >/dev/null 2>&1 || :
QUIRK_TABLE="$probe_table"
quirk_value "$probe_mfr" "$probe_model" "$probe_fw" "$probe_key" 2>/dev/null ||
	printf '%s\n' '<none>'
PROBE
quirk_probe() {
	QUIRK_SCRIPT="$SCRIPT" sh "$STATE/quirk-probe" "$@"
}
[ "$(quirk_probe "$quirk_fixture" 'Fibocom Wireless Inc.' FM350-GL 'some-other-firmware' example_capability)" = general ] || \
	fail 'a wildcard firmware entry did not match'
[ "$(quirk_probe "$quirk_fixture" 'Fibocom Wireless Inc.' FM350-GL '81600.0000.00.29.21.27' example_capability)" = firmware-specific ] || \
	fail 'a firmware-specific entry did not win over the wildcard'
[ "$(quirk_probe "$quirk_fixture" 'Fibocom Wireless Inc.' FM350-GL '*' unknown_capability)" = '<none>' ] || \
	fail 'an unknown key returned something'
[ "$(quirk_probe "$quirk_fixture" 'Some Vendor' 'Some Model' '*' example_capability)" = '<none>' ] || \
	fail 'an untested modem inherited another modem quirk'
[ "$(quirk_probe "$quirk_fixture" 'Fibocom Wireless Inc.' FM350-GL '*' truncated_capability)" = '<none>' ] || \
	fail 'a row with no value produced one'
# The NF and comment guards in the lookup are deliberate but redundant: a short
# row already fails the field comparison and an empty value already fails the
# emptiness check. They are kept as intent, not asserted as behaviour, because a
# test that cannot fail is worse than no test.
[ "$(quirk_probe "$BASE/apn-autoconfig-modem/files/usr/share/apn-autoconfig-modem/quirks" \
	'Fibocom Wireless Inc.' FM350-GL '*' example_capability)" = '<none>' ] || \
	fail 'the shipped quirk table is not empty'

printf '%s\n' 'TEST the reset method is chosen by control owner, and gpio wins where it is available'
reset_sysfs
reset_at_ports
reset_network_config
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0 wwan0
add_at_port 1-1.2 80 1.5 control
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID
# A resolved AT port must not displace the board power cycle: gpio is out of
# band, needs no control channel, and is the released behaviour.
sh "$SCRIPT" at-port --modem "$TEST_RESET_MODEM_ID" >/dev/null || fail 'the pinned modem did not resolve an AT port'
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["reset_method"] == "gpio", m
assert m["capabilities"]["reset"] is True, m
' "$(sh "$SCRIPT" inventory-json)" || fail 'a resolved AT port displaced the board reset'

printf '%s\n' 'TEST an AT-only modem gets the at method, and a soft reset that loses its port succeeds'
reset_sysfs
reset_at_ports
reset_network_config
add_at_modem 11-1.1 0e8d 7127 '' 81
printf '/dev/ttyUSB81\tcontrol-vanish\n' >>"$TEST_AT_PORTS"
AT_RESET_ID="weak-vidpid:11-1.1:0e8d:7127"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["reset_method"] == "none", m
assert m["capabilities"]["reset"] is False, m
' "$(sh "$SCRIPT" inventory-json)" || fail 'an unresolved AT modem already advertised a reset method'
sh "$SCRIPT" at-port --modem "$AT_RESET_ID" >/dev/null || fail 'the AT-only modem did not resolve'
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["reset_method"] == "at", m
assert m["capabilities"]["reset"] is True, m
' "$(sh "$SCRIPT" inventory-json)" || fail 'a resolved AT-only modem did not offer the at reset method'
: >"$TEST_AT_PROBES"
# A modem that stays on the bus has not reset, whatever the command returned.
# The full vanish-and-return cycle is deliberately NOT simulated: faking it
# needs sleeps racing an inventory scan, and the first attempt duly passed and
# failed on alternate runs. A test whose verdict depends on scheduling is worse
# than no test. Hardware validates the cycle; this asserts the rule that makes
# the cycle mean anything.
at_reset_status=0
sh "$SCRIPT" reset --modem "$AT_RESET_ID" >"$STATE/at-reset" 2>&1 || at_reset_status=$?
[ "$at_reset_status" -eq 3 ] || \
	fail "a modem that never left the bus exited $at_reset_status instead of the retryable class 3"
grep -q 'never left the bus' "$STATE/at-reset" || \
	fail 'an ineffective soft reset was not reported as such'
grep -q "AT+CFUN=1,1" "$TEST_AT_PROBES" || fail 'the soft reset never reached the modem'
[ ! -e "${TEST_AT_PORT_LOCK_ROOT}.ttyUSB81" ] || fail 'the soft reset left the AT port locked'

printf '%s\n' 'TEST a ModemManager-owned modem is reset by ModemManager, not around it'
reset_sysfs
reset_at_ports
reset_network_config
rm -f "$HARDWARE_MARKER"
add_qmi_modem 12-1.1 2c7c 0801 MMRESET 9 wwan9
add_at_port 12-1.1 82 1.5 control
MM_MODEM_INDEX=0
MM_DEVICE="$TESTROOT/sys/devices/platform/mock-usb/12-1.1"
MM_PHYSDEV="$MM_DEVICE"
export MM_MODEM_INDEX MM_DEVICE MM_PHYSDEV
MM_RESET_ID="usb-serial:12-1.1:2c7c:0801:MMRESET"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["owner_state"] == "modemmanager", m
assert m["reset_method"] == "modemmanager", m
' "$(sh "$SCRIPT" inventory-json)" || fail 'an owned modem did not select the modemmanager reset method'
: >"$TEST_MM_RESETS"
: >"$TEST_AT_PROBES"
mm_reset_status=0
sh "$SCRIPT" reset --modem "$MM_RESET_ID" >"$STATE/mm-reset" 2>&1 || mm_reset_status=$?
[ "$mm_reset_status" -eq 3 ] || \
	fail "an ineffective ModemManager reset exited $mm_reset_status instead of the retryable class 3"
grep -q 'never left the bus' "$STATE/mm-reset" || \
	fail 'an ineffective ModemManager reset was not reported as such'
grep -q "	reset" "$TEST_MM_RESETS" || fail 'ModemManager was never asked to reset its own modem'
[ ! -s "$TEST_AT_PROBES" ] || fail 'an owned modem was reached over AT during its reset'
unset MM_MODEM_INDEX MM_DEVICE MM_PHYSDEV
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"

printf '%s\n' 'TEST a second idle modem cannot satisfy the wait for the one being reset'
# Found on the reference router, not by fixtures. wait_for_control_owner passed
# its target to awk as "$modem_id" — the same name scan_inventory reassigns once
# per discovered record — so the comparison ran against whichever record was
# scanned last. A neighbouring idle modem matched immediately and the reset was
# reported complete seconds after it was issued, for a device that had not
# cycled. With one modem present the clobbered value equals the target, which is
# why this needs two.
reset_sysfs
reset_at_ports
reset_network_config
# The neighbour sorts last, so it is what the clobbered variable would hold.
add_qmi_modem 13-1.1 2c7c 0801 RESETTARGET 6
add_qmi_modem 13-1.2 2c7c 0801 ZNEIGHBOUR 7
cat >"$STATE/wait-probe" <<'PROBE'
#!/bin/sh
target="$1"; owner="$2"
set --
. "$WAIT_SCRIPT" >/dev/null 2>&1 || :
load_config
SYSFS_ROOT="$(readlink -f "$SYSFS_ROOT" 2>/dev/null || printf '%s' "$SYSFS_ROOT")"
MODEM_WAIT_SECONDS=2
MODEM_POLL_SECONDS=1
if wait_for_control_owner "$target" "$owner"; then printf 'matched\n'; else printf 'timeout\n'; fi
PROBE
# The named modem is not present at all, while the neighbour is present and
# idle. A wait that compares against its own target must time out.
verdict="$(WAIT_SCRIPT="$SCRIPT" sh "$STATE/wait-probe" 'usb-serial:13-1.9:2c7c:0801:ABSENT' none)"
[ "$verdict" = timeout ] || \
	fail 'an idle neighbouring modem satisfied the wait for a modem that is not present'
# Positive control, so the assertion above cannot pass by the wait being broken
# in the other direction.
verdict="$(WAIT_SCRIPT="$SCRIPT" sh "$STATE/wait-probe" 'usb-serial:13-1.1:2c7c:0801:RESETTARGET' none)"
[ "$verdict" = matched ] || fail 'the wait did not match its own target when that target was present'

printf '%s\n' 'TEST an in-band reset must see the modem leave the bus before its return counts'
# Also from the router. AT+CFUN=1,1 returns while the modem is still fully
# enumerated and only tears its interfaces down a moment later, so waiting
# straight for "present with the expected owner" was satisfied by the modem that
# had not started resetting yet — a reset reported complete in three seconds.
# Board power does not have this problem, which is why only the new methods do.
cat >"$STATE/depart-probe" <<'PROBE'
#!/bin/sh
target="$1"
set --
. "$WAIT_SCRIPT" >/dev/null 2>&1 || :
load_config
SYSFS_ROOT="$(readlink -f "$SYSFS_ROOT" 2>/dev/null || printf '%s' "$SYSFS_ROOT")"
MODEM_DEPART_SECONDS=2
MODEM_POLL_SECONDS=1
if wait_for_modem_departure "$target"; then printf 'departed\n'; else printf 'still-present\n'; fi
PROBE
verdict="$(WAIT_SCRIPT="$SCRIPT" sh "$STATE/depart-probe" 'usb-serial:13-1.1:2c7c:0801:RESETTARGET')"
[ "$verdict" = still-present ] || \
	fail 'a modem that never left the bus was treated as having reset'
verdict="$(WAIT_SCRIPT="$SCRIPT" sh "$STATE/depart-probe" 'usb-serial:13-9.9:2c7c:0801:VANISHED')"
[ "$verdict" = departed ] || fail 'an absent modem was not recognised as departed'

printf '%s\n' 'TEST reset refuses to run against a conflicting-ownership modem'
reset_sysfs
reset_network_config
add_qmi_modem 2-1.1 2c7c 0125 '' 3
add_network_section celldirect qmi /dev/cdc-wdm3
TEST_RESET_MODEM_ID='imei:490154203237999'
export TEST_RESET_MODEM_ID
if out="$(MM_MODEM_INDEX=0 MM_DEVICE=cdc-wdm3 MM_PHYSDEV="$TESTROOT/sys/devices/platform/mock-usb/2-1.1" MM_IMEI=490154203237999 \
	sh "$SCRIPT" reset --modem imei:490154203237999 2>&1)"; then
	fail 'reset should refuse a conflicting-ownership modem'
else
	[ "$?" -eq 4 ] || fail 'conflicting-ownership reset did not use exit code 4'
fi
reset_network_config

printf '%s\n' 'TEST action-start reset runs in background and action-status reflects completion'
reset_sysfs
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
start_out="$(sh "$SCRIPT" action-start reset --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["version"] == "v2"; assert d["accepted"] is True; assert d["operation_id"]' "$start_out" \
	|| fail 'action-start reset was not accepted'
waited=0
while [ "$waited" -lt 10 ]; do
	status_out="$(sh "$SCRIPT" action-status --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01)"
	state="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["state"])' "$status_out")"
	case "$state" in success|failed) break ;; esac
	waited=$((waited + 1))
	/bin/sleep 1
done
[ "$state" = success ] || fail "background reset action ended in state '$state', expected success: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("message"))' "$status_out")"

printf '%s\n' 'TEST simultaneous action-start requests atomically accept only one worker'
mv "$MOCKBIN/sleep" "$MOCKBIN/sleep.mock"
TEST_MODEM_POWER_OFF_SECONDS=3
export TEST_MODEM_POWER_OFF_SECONDS
sh "$SCRIPT" action-start reset --modem "$TEST_RESET_MODEM_ID" >"$STATE/start-one.json" &
start_one_pid=$!
sh "$SCRIPT" action-start reset --modem "$TEST_RESET_MODEM_ID" >"$STATE/start-two.json" &
start_two_pid=$!
wait "$start_one_pid"
wait "$start_two_pid"
accepted_count="$(python3 -c '
import json, sys
print(sum(1 for path in sys.argv[1:] if json.load(open(path))["accepted"]))
' "$STATE/start-one.json" "$STATE/start-two.json")"
[ "$accepted_count" -eq 1 ] || fail "parallel action-start accepted $accepted_count workers instead of exactly one"
waited=0
while [ "$waited" -lt 10 ]; do
	parallel_status_out="$(sh "$SCRIPT" action-status --modem "$TEST_RESET_MODEM_ID")"
	parallel_state="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["state"])' "$parallel_status_out")"
	case "$parallel_state" in success|blocked|retryable|failed) break ;; esac
	waited=$((waited + 1))
	/bin/sleep 1
done
mv "$MOCKBIN/sleep.mock" "$MOCKBIN/sleep"
TEST_MODEM_POWER_OFF_SECONDS=1
export TEST_MODEM_POWER_OFF_SECONDS
[ "$parallel_state" = success ] || fail "parallel action winner ended in state $parallel_state"

printf '%s\n' 'TEST a stale running state left by a dead PID does not block a new action-start'
action_modem_id='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
action_modem_dir="$TEST_MODEM_ACTION_DIR/usb-serial_1-1.2_2c7c_0801_RM520SERIAL01"
mkdir -p "$action_modem_dir"
printf 'v2\trunning\treset\t999999\t2026-01-01T00:00:00Z\t\t\toperation is running\t%s\tstale-operation\n' \
	"$action_modem_id" >"$action_modem_dir/state.tsv"
if kill -0 999999 2>/dev/null; then
	printf 'SKIP: PID 999999 is unexpectedly alive on this host\n'
else
	stale_out="$(sh "$SCRIPT" action-start reset --modem "$action_modem_id")"
	python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is True, d' "$stale_out" \
		|| fail 'a dead PID left over from a previous run should not block a new action-start indefinitely'
	waited=0
	while [ "$waited" -lt 10 ]; do
		stale_status_out="$(sh "$SCRIPT" action-status --modem "$action_modem_id")"
		stale_state="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["state"])' "$stale_status_out")"
		case "$stale_state" in success|blocked|retryable|failed) break ;; esac
		waited=$((waited + 1))
		/bin/sleep 1
	done
	[ "$stale_state" = success ] || fail "replacement action after stale PID did not complete: $stale_state"
fi

printf '%s\n' 'TEST a genuinely running action for a modem refuses a second concurrent start'
printf 'v2\trunning\treset\t%s\t2026-01-01T00:00:00Z\t\t\toperation is running\t%s\tbusy-operation\n' \
	"$$" "$action_modem_id" >"$action_modem_dir/state.tsv"
busy_out="$(sh "$SCRIPT" action-start reset --modem "$action_modem_id")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is False, d' "$busy_out" \
	|| fail 'a modem with a live-PID running action must refuse a second concurrent action-start'

# ---- lock-protocol regressions (0.10.1) ----
#
# 0.10.0 published a lock in two steps (mkdir, then write the PID). A
# competitor arriving between them read an empty PID, concluded the owner had
# crashed, deleted the live lock and proceeded. These cases pin the atomic
# replacement and the upgrade path from the old representation.

printf '%s\n' 'TEST a start lock owned by a live process is never stolen by a second launcher'
reset_sysfs
reset_network_config
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID
rm -rf "$TEST_MODEM_ACTION_DIR"
lock_state_dir="$TEST_MODEM_ACTION_DIR/usb-serial_1-1.2_2c7c_0801_RM520SERIAL01"
foreign_start_lock="${lock_state_dir}.start-lock"
mkdir -p "$TEST_MODEM_ACTION_DIR"
/bin/sleep 30 &
foreign_pid=$!
printf '%s\n' "$foreign_pid" >"$foreign_start_lock"
steal_out="$(sh "$SCRIPT" action-start reset --modem "$TEST_RESET_MODEM_ID")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is False, d' "$steal_out" \
	|| fail 'action-start stole a start lock held by a live owner'
[ "$(sed -n '1p' "$foreign_start_lock" 2>/dev/null)" = "$foreign_pid" ] || \
	fail 'the live owner of a start lock was overwritten by a competing launcher'
kill "$foreign_pid" 2>/dev/null || :
wait "$foreign_pid" 2>/dev/null || :
rm -f "$foreign_start_lock"

printf '%s\n' 'TEST repeated parallel launches accept exactly one worker every time'
mv "$MOCKBIN/sleep" "$MOCKBIN/sleep.mock"
TEST_MODEM_POWER_OFF_SECONDS=3
export TEST_MODEM_POWER_OFF_SECONDS
parallel_round=0
while [ "$parallel_round" -lt 8 ]; do
	parallel_round=$((parallel_round + 1))
	rm -rf "$TEST_MODEM_ACTION_DIR"
	sh "$SCRIPT" action-start reset --modem "$TEST_RESET_MODEM_ID" >"$STATE/race-a.json" 2>/dev/null &
	race_a=$!
	sh "$SCRIPT" action-start reset --modem "$TEST_RESET_MODEM_ID" >"$STATE/race-b.json" 2>/dev/null &
	race_b=$!
	wait "$race_a" || :
	wait "$race_b" || :
	race_accepted="$(python3 -c '
import json, sys
count = 0
for path in sys.argv[1:]:
    try:
        count += 1 if json.load(open(path))["accepted"] else 0
    except Exception:
        pass
print(count)
' "$STATE/race-a.json" "$STATE/race-b.json")"
	[ "$race_accepted" -eq 1 ] || \
		fail "parallel launch round $parallel_round accepted $race_accepted workers instead of exactly one"
	race_wait=0
	while [ "$race_wait" -lt 15 ]; do
		race_state="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["state"])' \
			"$(sh "$SCRIPT" action-status --modem "$TEST_RESET_MODEM_ID")")"
		case "$race_state" in success|blocked|retryable|failed) break ;; esac
		race_wait=$((race_wait + 1))
		/bin/sleep 1
	done
done
mv "$MOCKBIN/sleep.mock" "$MOCKBIN/sleep"
TEST_MODEM_POWER_OFF_SECONDS=1
export TEST_MODEM_POWER_OFF_SECONDS

if kill -0 999999 2>/dev/null; then
	printf 'SKIP: PID 999999 is unexpectedly alive on this host\n'
else
	printf '%s\n' 'TEST the launcher-to-worker handoff is reported busy rather than as a dead worker'
	rm -rf "$TEST_MODEM_ACTION_DIR"
	mkdir -p "$lock_state_dir"
	/bin/sleep 30 &
	handoff_pid=$!
	printf '%s\n' "$handoff_pid" >"${lock_state_dir}.start-lock"
	printf 'v2\tstarting\treset\t999999\t2026-01-01T00:00:00Z\t\t\tstarting background worker\t%s\thandoff-op\n' \
		"$TEST_RESET_MODEM_ID" >"$lock_state_dir/state.tsv"
	handoff_out="$(sh "$SCRIPT" action-status --modem "$TEST_RESET_MODEM_ID")"
	python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["state"] == "starting", d
assert d["busy"] is True, d
' "$handoff_out" || fail 'an accepted worker that has not written its first record was reported as failed'

	printf '%s\n' 'TEST a worker that really died without a start lock still reaches a terminal failure'
	rm -f "${lock_state_dir}.start-lock"
	dead_out="$(sh "$SCRIPT" action-status --modem "$TEST_RESET_MODEM_ID")"
	python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["state"] == "failed", d
assert d["busy"] is False, d
' "$dead_out" || fail 'a genuinely dead worker must still terminate the operation'
	kill "$handoff_pid" 2>/dev/null || :
	wait "$handoff_pid" 2>/dev/null || :
	rm -rf "$TEST_MODEM_ACTION_DIR"
fi

printf '%s\n' 'TEST a 0.10.0 directory-style identity lock is honored while its owner is alive'
reset_sysfs
add_qmi_modem 1-1.3 2c7c 0801 '' 1
legacy_lock="${TEST_QMI_IDENTITY_LOCK_ROOT}.cdc-wdm1"
mkdir -p "$(dirname "$TEST_QMI_IDENTITY_LOCK_ROOT")"
rm -rf "$legacy_lock"
mkdir "$legacy_lock"
printf '%s\n' "$$" >"$legacy_lock/pid"
: >"$TEST_UQMI_CALLS"
legacy_out="$(UQMI_IMEI=490154203237518 sh "$SCRIPT" inventory-json)"
[ ! -s "$TEST_UQMI_CALLS" ] || \
	fail 'inventory opened QMI while a live owner held the pre-upgrade lock directory'
[ -d "$legacy_lock" ] || fail 'a lock directory owned by a live process was removed'
python3 -c 'import json,sys; assert json.loads(sys.argv[1])["modems"][0]["evidence_tier"] == "weak-vidpid"' \
	"$legacy_out" || fail 'a held pre-upgrade lock did not degrade to weak read-only inventory'

if kill -0 999999 2>/dev/null; then
	printf 'SKIP: PID 999999 is unexpectedly alive on this host\n'
else
	printf '%s\n' 'TEST a 0.10.0 lock directory left by a dead owner is reclaimed instead of deadlocking'
	printf '%s\n' 999999 >"$legacy_lock/pid"
	: >"$TEST_UQMI_CALLS"
	reclaimed_out="$(UQMI_IMEI=490154203237518 sh "$SCRIPT" inventory-json)"
	[ -s "$TEST_UQMI_CALLS" ] || \
		fail 'a pre-upgrade lock directory left by a dead owner blocked identity for good'
	python3 -c 'import json,sys; assert json.loads(sys.argv[1])["modems"][0]["evidence_tier"] == "imei"' \
		"$reclaimed_out" || fail 'identity did not recover after reclaiming a stale pre-upgrade lock'
	if [ -e "$legacy_lock" ]; then
		fail 'the reclaimed pre-upgrade lock was left behind'
	fi
fi
rm -rf "$legacy_lock"

if kill -0 999999 2>/dev/null; then
	printf 'SKIP: PID 999999 is unexpectedly alive on this host\n'
else
	printf '%s\n' 'TEST a hotplug debounce marker left by a dead worker does not disable later rescans'
	debounce_lock="${TEST_MODEM_LOCK_ROOT}.hotplug-debounce"
	rm -rf "$debounce_lock"
	printf '%s\n' 999999 >"$debounce_lock"
	reset_sysfs
	add_qmi_modem 1-1.1 2c7c 0801 '' 9
	: >"$TEST_UQMI_CALLS"
	ACTION=add APN_AUTOCONFIG_MODEM_BIN="$SCRIPT" sh "$HOTPLUG_SCRIPT"
	/bin/sleep 2
	[ -s "$TEST_UQMI_CALLS" ] || \
		fail 'a stale debounce marker silently swallowed every later hotplug rescan'
	rm -f "$debounce_lock"
fi

printf '%s\n' 'TEST the coordinator reports shared APN lock contention as retryable, not failed'
reset_sysfs
reset_network_config
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0
add_network_section cellqmi qmi /dev/cdc-wdm0
TEST_RESET_MODEM_ID='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
export TEST_RESET_MODEM_ID
/bin/sleep 30 &
apn_owner_pid=$!
mkdir -p "$(dirname "$TEST_APN_LOCK_DIR")"
rm -rf "$TEST_APN_LOCK_DIR"
printf '%s\n' "$apn_owner_pid" >"$TEST_APN_LOCK_DIR"
: >"$TEST_EVENTS"
contended_status=0
sh "$SCRIPT" reset --modem "$TEST_RESET_MODEM_ID" >/dev/null 2>&1 || contended_status=$?
[ "$contended_status" -eq 3 ] || \
	fail "contention on the shared APN lock exited $contended_status instead of the retryable class 3"
[ ! -s "$TEST_EVENTS" ] || fail 'a blocked reset still touched the selected interface'
[ "$(cat "$GPIO")" = 0 ] || fail 'a blocked reset still moved the modem power GPIO'
[ "$(sed -n '1p' "$TEST_APN_LOCK_DIR" 2>/dev/null)" = "$apn_owner_pid" ] || \
	fail 'a blocked reset stole the shared APN lock from its live owner'
kill "$apn_owner_pid" 2>/dev/null || :
wait "$apn_owner_pid" 2>/dev/null || :
rm -f "$TEST_APN_LOCK_DIR"

# ---- provisioning planning (0.11.0, read-only) ----
#
# See docs/provisioning-contract-v1.md. provision-plan must never write UCI,
# never create state and never open a control channel; every refusal is a
# stable machine-readable reason.

plan_json() {
	plan_out="$1"
	plan_key="$2"
	python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$plan_out" "$plan_key"
}

printf '%s\n' 'TEST provision-plan accepts one unambiguous unconfigured QMI modem'
reset_sysfs
reset_network_config
add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0
plan_modem='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
plan_status=0
plan_out="$(sh "$SCRIPT" provision-plan --modem "$plan_modem")" || plan_status=$?
[ "$plan_status" -eq 0 ] || fail "provision-plan on a provisionable modem exited $plan_status"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["version"] == "v1", d
assert d["can_provision"] is True, d
assert d["reason"] == "ok", d
assert d["section"] == "apnmodem1", d
assert d["protocol"] == "qmi", d
assert d["device"] == "/dev/cdc-wdm0", d
' "$plan_out" || fail 'provision-plan did not accept an unconfigured QMI modem'

printf '%s\n' 'TEST provision-plan is read-only'
plan_sections_before="$(cat "$TEST_NETWORK_SECTIONS")"
plan_options_before="$(cat "$TEST_NETWORK_OPTIONS")"
: >"$TEST_UQMI_CALLS"
sh "$SCRIPT" provision-plan --modem "$plan_modem" >/dev/null
[ "$plan_sections_before" = "$(cat "$TEST_NETWORK_SECTIONS")" ] || \
	fail 'provision-plan modified network sections'
[ "$plan_options_before" = "$(cat "$TEST_NETWORK_OPTIONS")" ] || \
	fail 'provision-plan modified network options'
[ ! -s "$TEST_UQMI_CALLS" ] || fail 'provision-plan opened a QMI control channel'

printf '%s\n' 'TEST provision-plan refuses a modem that is already bound to an interface'
add_network_section wwanexisting qmi /dev/cdc-wdm0
plan_status=0
plan_out="$(sh "$SCRIPT" provision-plan --modem "$plan_modem")" || plan_status=$?
[ "$plan_status" -eq 4 ] || fail "an already configured modem exited $plan_status instead of the blocked class 4"
[ "$(plan_json "$plan_out" reason)" = already_configured ] || \
	fail 'an already configured modem did not report already_configured'
[ "$(plan_json "$plan_out" can_provision)" = False ] || \
	fail 'an already configured modem was reported provisionable'

printf '%s\n' 'TEST provision-plan picks the lowest free section name'
reset_network_config
add_plain_section apnmodem1
add_plain_section apnmodem2
plan_out="$(sh "$SCRIPT" provision-plan --modem "$plan_modem")"
[ "$(plan_json "$plan_out" section)" = apnmodem3 ] || \
	fail 'provision-plan did not choose the lowest free section name'

printf '%s\n' 'TEST provision-plan reports an existing project-owned section instead of a second one'
reset_network_config
add_network_section apnmodem1 qmi /dev/cdc-wdm0
add_section_option apnmodem1 apn_autoconfig_owner apn-autoconfig-modem
add_section_option apnmodem1 apn_autoconfig_modem_id "$plan_modem"
plan_out="$(sh "$SCRIPT" provision-plan --modem "$plan_modem")"
[ "$(plan_json "$plan_out" reason)" = already_provisioned ] || \
	fail 'an existing project-owned section was not recognised'
[ "$(plan_json "$plan_out" existing_section)" = apnmodem1 ] || \
	fail 'the existing project-owned section was not reported'

printf '%s\n' 'TEST a section that only looks project-owned is never claimed'
reset_network_config
add_network_section apnmodem1 qmi /dev/cdc-wdm0
add_section_option apnmodem1 apn_autoconfig_modem_id "$plan_modem"
plan_status=0
plan_out="$(sh "$SCRIPT" provision-plan --modem "$plan_modem")" || plan_status=$?
[ "$(plan_json "$plan_out" existing_section)" = '' ] || \
	fail 'a section without the ownership marker was treated as project-owned'
[ "$(plan_json "$plan_out" reason)" = already_configured ] || \
	fail 'an unowned section bound to the modem must block provisioning, not be adopted'

printf '%s\n' 'TEST provision-plan refuses an ambiguous modem without inspecting it further'
reset_sysfs
reset_network_config
add_qmi_modem 4-1.1 1bc7 1900 '' 6
add_qmi_modem 4-1.2 1bc7 1900 '' 7
plan_status=0
plan_out="$(sh "$SCRIPT" provision-plan --modem weak-vidpid:4-1.1:1bc7:1900)" || plan_status=$?
[ "$plan_status" -eq 4 ] || fail "an ambiguous modem exited $plan_status instead of the blocked class 4"
[ "$(plan_json "$plan_out" reason)" = ambiguous ] || \
	fail 'an ambiguous modem did not report the ambiguous reason'

printf '%s\n' 'TEST provision-plan refuses an AT-only modem as an unsupported protocol'
reset_sysfs
reset_network_config
add_at_modem 5-1.1 1bc7 1901 ATONLYSERIAL 4
plan_status=0
plan_out="$(sh "$SCRIPT" provision-plan --modem usb-serial:5-1.1:1bc7:1901:ATONLYSERIAL)" || plan_status=$?
[ "$plan_status" -eq 4 ] || fail "an AT-only modem exited $plan_status instead of the blocked class 4"
[ "$(plan_json "$plan_out" reason)" = unsupported_protocol ] || \
	fail 'an AT-only modem was not refused as an unsupported provisioning protocol'

printf '%s\n' 'TEST provision-plan reports an absent modem as retryable, not blocked'
reset_sysfs
reset_network_config
plan_status=0
plan_out="$(sh "$SCRIPT" provision-plan --modem usb-serial:9-9.9:0000:0000:ABSENT)" || plan_status=$?
[ "$plan_status" -eq 3 ] || fail "an absent modem exited $plan_status instead of the retryable class 3"
[ "$(plan_json "$plan_out" reason)" = not_present ] || \
	fail 'an absent modem did not report not_present'

printf '%s\n' 'TEST provision-plan requires an explicit modem identity'
if sh "$SCRIPT" provision-plan >/dev/null 2>&1; then
	fail 'provision-plan ran without --modem'
fi

# ---- provisioning mutation, rollback and removal (0.11.0) ----

# A stand-in APN engine, so provisioning can be exercised without the real one.
# It records how it was invoked, which is how the borrowed-lock contract and the
# "reconcile only after staging" ordering are asserted.
setup_apn_engine_mock() {
	cat >"$MOCKBIN/apn-autoconfig" <<'MOCKEOF'
#!/bin/sh
printf '%s\towner_pid=%s\tsection_disabled=%s\tsection_apn=%s\n' \
	"$*" "${APN_AUTOCONFIG_LOCK_OWNER_PID:-none}" \
	"$(uci -q get "network.${3#network:}.disabled" 2>/dev/null || printf 'unset')" \
	"$(uci -q get "network.${3#network:}.apn" 2>/dev/null || printf 'unset')" \
	>>"$TEST_RECONCILE_CALLS"
# Publishes its own PID and then holds the operation open, so a signal can be
# delivered while the staging section exists and the locks are held. Checking
# that PID afterwards detects an engine left running as an orphan.
case "${1:-}" in
forget-target)
	# Mirrors the engine: drop only this target's state directory.
	section="${3#network:}"
	rm -rf "$TEST_ENGINE_STATE/targets/network_${section}"
	exit "${FORGET_EXIT:-0}"
;;
esac
printf '%s\n' "$$" >"$TEST_RECONCILE_PID"
[ "${RECONCILE_HANG:-0}" = 1 ] && /bin/sleep 30
exit "${RECONCILE_EXIT:-0}"
MOCKEOF
	chmod 0755 "$MOCKBIN/apn-autoconfig"
}
export TEST_RECONCILE_CALLS="$STATE/reconcile-calls"
export TEST_RECONCILE_PID="$STATE/reconcile-pid"
export TEST_ENGINE_STATE="$STATE/engine-state"

# Records how the narrow control wrapper invokes the coordinator, so the
# wrapper's forwarding can be asserted without starting real operations.
cat >"$MOCKBIN/record-modem-bin" <<'RECEOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_STATE/control-calls"
exit 0
RECEOF
chmod 0755 "$MOCKBIN/record-modem-bin"
: >"$STATE/control-calls"
setup_apn_engine_mock

provision_fixture() {
	reset_sysfs
	reset_network_config
	add_qmi_modem 1-1.2 2c7c 0801 RM520SERIAL01 0
	rm -rf "$TEST_MODEM_STATE_DIR/provisioning"
	: >"$TEST_RECONCILE_CALLS"
	: >"$TEST_EVENTS"
	PROV_MODEM='usb-serial:1-1.2:2c7c:0801:RM520SERIAL01'
}

printf '%s\n' 'TEST provision creates one staged, marked, project-owned section and promotes it'
provision_fixture
prov_out="$(sh "$SCRIPT" provision --modem "$PROV_MODEM")" || fail 'provision failed on a provisionable modem'
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["version"] == "v1", d
assert d["section"] == "apnmodem1", d
assert d["protocol"] == "qmi", d
assert d["state"] == "promoted", d
assert d["autoconnect"] is True, d
' "$prov_out" || fail 'provision did not report a promoted project-owned section'
[ "$(uci -q get network.apnmodem1.apn_autoconfig_owner)" = apn-autoconfig-modem ] || \
	fail 'the created section is not marked as project-owned'
[ "$(uci -q get network.apnmodem1.apn_autoconfig_modem_id)" = "$PROV_MODEM" ] || \
	fail 'the created section does not record the modem identity'
[ -n "$(uci -q get network.apnmodem1.apn_autoconfig_provisioned)" ] || \
	fail 'the created section does not record a provisioning timestamp'
[ "$(uci -q get network.apnmodem1.proto)" = qmi ] || fail 'the created section has the wrong protocol'
[ "$(uci -q get network.apnmodem1.device)" = /dev/cdc-wdm0 ] || fail 'the created section has the wrong device'

printf '%s\n' 'TEST the staged section can never dial a default APN before reconciliation'
grep -q "section_disabled=1" "$TEST_RECONCILE_CALLS" && \
	fail 'reconcile ran while the section was still administratively disabled'
grep -q "section_apn=unset" "$TEST_RECONCILE_CALLS" || \
	fail 'the section carried an apn option before the APN engine chose one'
grep -F -q "reconcile --target network:apnmodem1" "$TEST_RECONCILE_CALLS" || \
	fail 'provisioning did not reconcile the section it created'

printf '%s\n' 'TEST provisioning hands the APN engine a proven borrowed lock rather than a bare variable'
grep -q "owner_pid=none" "$TEST_RECONCILE_CALLS" && \
	fail 'the APN engine was invoked without the coordinator lock owner'
grep -qE "owner_pid=[0-9]+" "$TEST_RECONCILE_CALLS" || \
	fail 'the borrowed lock owner PID was not passed to the APN engine'

printf '%s\n' 'TEST provisioning never starts the section itself'
# Bringing the section up before the APN engine has written a profile would
# hand netifd a cellular section with no apn - the vendor-default dial staging
# exists to prevent. Clearing "disabled" only makes it startable; the engine
# owns bring-up.
grep -F -q "up apnmodem1" "$TEST_EVENTS" && \
	fail 'provisioning started the section before the APN engine chose a profile'

printf '%s\n' 'TEST provisioning promotes autoconnect only after reconciliation succeeded'
[ -z "$(uci -q get network.apnmodem1.auto)" ] || \
	fail 'a promoted section should not keep auto=0'

printf '%s\n' 'TEST provisioning touches only the section it created'
untouched="$(uci_touched_only_section apnmodem1)" || \
	fail "provisioning wrote to unrelated sections: $untouched"

printf '%s\n' 'TEST an MBIM modem is provisioned as an MBIM section on its control device'
reset_sysfs
reset_network_config
add_mbim_modem 2-1.3 2cb7 0007 MBIMSERIAL02 4 wwan4
rm -rf "$TEST_MODEM_STATE_DIR/provisioning"
: >"$TEST_RECONCILE_CALLS"
: >"$TEST_EVENTS"
mbim_prov_modem='usb-serial:2-1.3:2cb7:0007:MBIMSERIAL02'
mbim_plan_out="$(sh "$SCRIPT" provision-plan --modem "$mbim_prov_modem")" || \
	fail 'provision-plan refused a provisionable MBIM modem'
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["can_provision"] is True, d
assert d["protocol"] == "mbim", d
assert d["device"] == "/dev/cdc-wdm4", d
' "$mbim_plan_out" || fail 'provision-plan did not plan an MBIM section'
[ ! -s "$TEST_UMBIM_CALLS" ] || fail 'planning an MBIM modem opened a control channel'
mbim_prov_out="$(sh "$SCRIPT" provision --modem "$mbim_prov_modem")" || \
	fail 'provision failed on a provisionable MBIM modem'
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["protocol"] == "mbim", d
assert d["state"] == "promoted", d
' "$mbim_prov_out" || fail 'provisioning an MBIM modem did not promote its section'
[ "$(uci -q get network.apnmodem1.proto)" = mbim ] || fail 'the created MBIM section has the wrong protocol'
[ "$(uci -q get network.apnmodem1.device)" = /dev/cdc-wdm4 ] || fail 'the created MBIM section has the wrong device'
[ "$(uci -q get network.apnmodem1.apn_autoconfig_owner)" = apn-autoconfig-modem ] || \
	fail 'the created MBIM section is not marked as project-owned'
grep -q "section_apn=unset" "$TEST_RECONCILE_CALLS" || \
	fail 'the MBIM section carried an apn option before the APN engine chose one'
grep -F -q "reconcile --target network:apnmodem1" "$TEST_RECONCILE_CALLS" || \
	fail 'provisioning did not reconcile the MBIM section it created'
grep -F -q "up apnmodem1" "$TEST_EVENTS" && \
	fail 'provisioning started the MBIM section before the APN engine chose a profile'
untouched="$(uci_touched_only_section apnmodem1)" || \
	fail "MBIM provisioning wrote to unrelated sections: $untouched"
[ ! -s "$TEST_UMBIM_CALLS" ] || fail 'provisioning an MBIM modem opened a control channel itself'
# A provisioned modem must not take the default route away from an uplink that
# already works. netifd's own default is metric 0, which does exactly that.
[ "$(uci -q get network.apnmodem1.metric)" = 1024 ] || \
	fail 'the created MBIM section did not get the conservative route metric'

printf '%s\n' 'TEST the provisioning route metric is configurable and can be switched off'
sh "$SCRIPT" deprovision --modem "$mbim_prov_modem" >/dev/null || fail 'deprovision failed before the metric test'
TEST_PROVISION_METRIC=77
export TEST_PROVISION_METRIC
sh "$SCRIPT" provision --modem "$mbim_prov_modem" >/dev/null || fail 'provision failed with a configured metric'
[ "$(uci -q get network.apnmodem1.metric)" = 77 ] || fail 'the configured route metric was ignored'
sh "$SCRIPT" deprovision --modem "$mbim_prov_modem" >/dev/null || fail 'deprovision failed after the metric test'
TEST_PROVISION_METRIC=''
export TEST_PROVISION_METRIC
sh "$SCRIPT" provision --modem "$mbim_prov_modem" >/dev/null || fail 'provision failed with an empty metric'
[ -z "$(uci -q get network.apnmodem1.metric)" ] || \
	fail 'an empty metric still wrote one instead of leaving the netifd default'
TEST_PROVISION_METRIC=1024
export TEST_PROVISION_METRIC

printf '%s\n' 'TEST deprovision removes an MBIM section exactly as it does a QMI one'
sh "$SCRIPT" deprovision --modem "$mbim_prov_modem" >/dev/null || \
	fail 'deprovision failed for an MBIM section'
[ -z "$(uci -q get network.apnmodem1.proto)" ] || fail 'deprovision left the MBIM section behind'

printf '%s\n' 'TEST provision refuses a second section for an already provisioned modem'
provision_fixture
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null || fail 'provision failed on a provisionable modem'
second_status=0
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null 2>&1 || second_status=$?
[ "$second_status" -eq 4 ] || fail "a repeated provision exited $second_status instead of the blocked class 4"
[ "$(network_section_count apnmodem)" -eq 1 ] || fail 'a repeated provision created a second section'

printf '%s\n' 'TEST deprovision asks the engine to forget the deleted target'
mkdir -p "$TEST_ENGINE_STATE/targets/network_apnmodem1"
printf 'v3\tapnmodem1\tnetwork:apnmodem1\tmodemmanager\tmodemmanager\n' \
	>"$TEST_ENGINE_STATE/targets/network_apnmodem1/baseline.tsv"
mkdir -p "$TEST_ENGINE_STATE/targets/network_other"
printf 'v3\tother\tnetwork:other\tqmi\tqmi\n' \
	>"$TEST_ENGINE_STATE/targets/network_other/baseline.tsv"

printf '%s\n' 'TEST deprovision removes exactly the project-owned section and its state'
deprov_out="$(sh "$SCRIPT" deprovision --modem "$PROV_MODEM")" || fail 'deprovision failed'
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["state"] == "removed", d
assert d["section"] == "apnmodem1", d
assert d["engine_state"] == "dropped", d
' "$deprov_out" || fail 'deprovision did not report the removed section and dropped engine state'
[ ! -e "$TEST_ENGINE_STATE/targets/network_apnmodem1" ] || \
	fail 'deprovision left the engine state for the deleted target behind'
[ -f "$TEST_ENGINE_STATE/targets/network_other/baseline.tsv" ] || \
	fail 'deprovision dropped engine state belonging to an unrelated target'
[ -z "$(uci -q get network.apnmodem1.proto)" ] || fail 'deprovision left the section behind'
grep -F -q "down apnmodem1" "$TEST_EVENTS" || fail 'deprovision did not stop the interface first'
[ ! -e "$TEST_MODEM_STATE_DIR/provisioning/usb-serial_1-1.2_2c7c_0801_RM520SERIAL01.tsv" ] || \
	fail 'deprovision left the provisioning baseline behind'

printf '%s\n' 'TEST deprovision refuses a section that is not marked project-owned'
provision_fixture
add_network_section handmade qmi /dev/cdc-wdm0
add_section_option handmade apn_autoconfig_modem_id "$PROV_MODEM"
unowned_status=0
sh "$SCRIPT" deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || unowned_status=$?
[ "$unowned_status" -eq 4 ] || fail "deprovision of an unowned section exited $unowned_status instead of 4"
[ "$(uci -q get network.handmade.proto)" = qmi ] || fail 'deprovision deleted a section it does not own'

printf '%s\n' 'TEST a failed reconciliation rolls the staging section back completely'
provision_fixture
RECONCILE_EXIT=1
export RECONCILE_EXIT
rollback_status=0
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null 2>&1 || rollback_status=$?
RECONCILE_EXIT=0
export RECONCILE_EXIT
[ "$rollback_status" -eq 4 ] || fail "a failed reconciliation exited $rollback_status instead of 4"
[ -z "$(uci -q get network.apnmodem1.proto)" ] || fail 'a failed reconciliation left the staging section behind'
[ "$(network_section_count apnmodem)" -eq 0 ] || fail 'rollback left a project-owned section behind'
[ ! -e "$TEST_MODEM_STATE_DIR/provisioning/usb-serial_1-1.2_2c7c_0801_RM520SERIAL01.tsv" ] || \
	fail 'rollback left the provisioning baseline behind'
grep -F -q "down apnmodem1" "$TEST_EVENTS" || fail 'rollback did not stop the interface it had started'
untouched="$(uci_touched_only_section apnmodem1)" || \
	fail "rollback wrote to unrelated sections: $untouched"

printf '%s\n' 'TEST a retryable reconciliation keeps the retryable exit class through provisioning'
provision_fixture
RECONCILE_EXIT=3
export RECONCILE_EXIT
retry_status=0
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null 2>&1 || retry_status=$?
RECONCILE_EXIT=0
export RECONCILE_EXIT
[ "$retry_status" -eq 3 ] || fail "a retryable reconciliation exited $retry_status instead of 3"
[ "$(network_section_count apnmodem)" -eq 0 ] || fail 'a retryable failure left a staging section behind'

printf '%s\n' 'TEST provisioning refuses to start while another operation holds the shared APN lock'
provision_fixture
/bin/sleep 30 &
prov_lock_pid=$!
mkdir -p "$(dirname "$TEST_APN_LOCK_DIR")"
rm -rf "$TEST_APN_LOCK_DIR"
printf '%s\n' "$prov_lock_pid" >"$TEST_APN_LOCK_DIR"
busy_status=0
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null 2>&1 || busy_status=$?
[ "$busy_status" -eq 3 ] || fail "contended provisioning exited $busy_status instead of the retryable class 3"
uci_wrote_nothing || fail 'a blocked provisioning attempt still wrote network configuration'
kill "$prov_lock_pid" 2>/dev/null || :
wait "$prov_lock_pid" 2>/dev/null || :
rm -f "$TEST_APN_LOCK_DIR"

printf '%s\n' 'TEST a real TERM during provisioning rolls back and releases both locks'
provision_fixture
RECONCILE_HANG=1
export RECONCILE_HANG
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null 2>&1 &
term_pid=$!
term_wait=0
while [ "$term_wait" -lt 100 ]; do
	[ -n "$(uci -q get network.apnmodem1.apn_autoconfig_owner 2>/dev/null)" ] && break
	term_wait=$((term_wait + 1))
	/bin/sleep 0.1
done
[ -n "$(uci -q get network.apnmodem1.apn_autoconfig_owner 2>/dev/null)" ] || \
	fail 'the signal test never observed the staging section it needs to interrupt'
kill -TERM "$term_pid"
term_status=0
wait "$term_pid" || term_status=$?
RECONCILE_HANG=0
export RECONCILE_HANG
[ "$term_status" -eq 143 ] || fail "interrupted provisioning exited $term_status instead of 143"
# The engine must be terminated and reaped, not left running against a target
# that is about to be deleted underneath it.
orphan_pid="$(cat "$TEST_RECONCILE_PID" 2>/dev/null || :)"
# The coordinator signals the engine and reaps it, but a shell sitting in a
# foreground sleep takes a moment to actually go away, and on a loaded machine
# that moment can outlast the coordinator. Anything still alive after a bounded
# grace period is genuinely orphaned; anything that dies inside it is not.
orphan_wait=0
while [ -n "$orphan_pid" ] && [ "$orphan_wait" -lt 20 ] && kill -0 "$orphan_pid" 2>/dev/null; do
	orphan_wait=$((orphan_wait + 1))
	/bin/sleep 0.1
done
if [ -n "$orphan_pid" ] && kill -0 "$orphan_pid" 2>/dev/null; then
	kill -TERM "$orphan_pid" 2>/dev/null || :
	fail 'the APN engine was left running as an orphan after the interruption'
fi
[ "$(network_section_count apnmodem)" -eq 0 ] || \
	fail 'interrupted provisioning left its staging section behind'
[ ! -e "$TEST_MODEM_STATE_DIR/provisioning/usb-serial_1-1.2_2c7c_0801_RM520SERIAL01.tsv" ] || \
	fail 'interrupted provisioning left the baseline behind'
[ ! -e "$TEST_APN_LOCK_DIR" ] || fail 'interrupted provisioning left the shared APN lock behind'
[ ! -e "${TEST_MODEM_LOCK_ROOT}.usb-serial_1-1.2_2c7c_0801_RM520SERIAL01" ] || \
	fail 'interrupted provisioning left the per-modem lock behind'
untouched="$(uci_touched_only_section apnmodem1)" || \
	fail "interrupted provisioning wrote to unrelated sections: $untouched"

printf '%s\n' 'TEST two simultaneous provisioning attempts create exactly one section'
provision_fixture
sh "$SCRIPT" provision --modem "$PROV_MODEM" >"$STATE/prov-a.json" 2>/dev/null &
race_prov_a=$!
sh "$SCRIPT" provision --modem "$PROV_MODEM" >"$STATE/prov-b.json" 2>/dev/null &
race_prov_b=$!
prov_a_status=0; wait "$race_prov_a" || prov_a_status=$?
prov_b_status=0; wait "$race_prov_b" || prov_b_status=$?
prov_winners=0
[ "$prov_a_status" -eq 0 ] && prov_winners=$((prov_winners + 1))
[ "$prov_b_status" -eq 0 ] && prov_winners=$((prov_winners + 1))
[ "$prov_winners" -eq 1 ] || \
	fail "parallel provisioning produced $prov_winners winners instead of exactly one"
[ "$(network_section_count apnmodem)" -eq 1 ] || \
	fail 'parallel provisioning created more than one section'
sh "$SCRIPT" deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || :

printf '%s\n' 'TEST provisioning aborts without mutating when the chosen section name is taken'
provision_fixture
add_plain_section apnmodem1
add_plain_section apnmodem2
name_out="$(sh "$SCRIPT" provision --modem "$PROV_MODEM")" || fail 'provision failed with free names available'
[ "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["section"])' "$name_out")" = apnmodem3 ] || \
	fail 'provision did not skip the occupied section names'
sh "$SCRIPT" deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || :

# ---- connection control on a project-owned section ----

printf '%s\n' 'TEST connect brings up the project-owned section and reports netifd state'
provision_fixture
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null || fail 'provision failed'
: >"$TEST_EVENTS"
TEST_IFACE_UP=apnmodem1
export TEST_IFACE_UP
conn_out="$(sh "$SCRIPT" connect --modem "$PROV_MODEM")" || fail 'connect failed on an up interface'
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["section"] == "apnmodem1", d
assert d["action"] == "connect", d
assert d["state"] == "up", d
' "$conn_out" || fail 'connect did not report the interface as up'
grep -F -q "up apnmodem1" "$TEST_EVENTS" || fail 'connect did not ask netifd to start the interface'

printf '%s\n' 'TEST connection control drives an MBIM section the same way'
reset_sysfs
reset_network_config
add_mbim_modem 2-1.3 2cb7 0007 MBIMSERIAL02 4 wwan4
rm -rf "$TEST_MODEM_STATE_DIR/provisioning"
: >"$TEST_RECONCILE_CALLS"
: >"$TEST_EVENTS"
sh "$SCRIPT" provision --modem usb-serial:2-1.3:2cb7:0007:MBIMSERIAL02 >/dev/null || \
	fail 'provision failed for the MBIM connection-control fixture'
: >"$TEST_EVENTS"
mbim_conn_out="$(sh "$SCRIPT" connect --modem usb-serial:2-1.3:2cb7:0007:MBIMSERIAL02)" || \
	fail 'connect failed on a project-owned MBIM section'
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"]=="up" and d["action"]=="connect", d' \
	"$mbim_conn_out" || fail 'connect did not report the MBIM interface as up'
grep -F -q "up apnmodem1" "$TEST_EVENTS" || fail 'connect did not ask netifd to start the MBIM interface'
sh "$SCRIPT" disconnect --modem usb-serial:2-1.3:2cb7:0007:MBIMSERIAL02 >/dev/null || \
	fail 'disconnect failed on a project-owned MBIM section'
[ ! -s "$TEST_UMBIM_CALLS" ] || fail 'connection control talked to the modem instead of netifd'
provision_fixture
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null || fail 'provision failed'
TEST_IFACE_UP=apnmodem1
export TEST_IFACE_UP
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null || fail 'connect failed on an up interface'

printf '%s\n' 'TEST disconnect stops the section and reconnect cycles it'
: >"$TEST_EVENTS"
disc_out="$(sh "$SCRIPT" disconnect --modem "$PROV_MODEM")" || fail 'disconnect failed'
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["state"]=="down" and d["action"]=="disconnect", d' \
	"$disc_out" || fail 'disconnect did not report the interface as down'
grep -F -q "down apnmodem1" "$TEST_EVENTS" || fail 'disconnect did not ask netifd to stop the interface'
: >"$TEST_EVENTS"
sh "$SCRIPT" reconnect --modem "$PROV_MODEM" >/dev/null || fail 'reconnect failed'
grep -F -q "down apnmodem1" "$TEST_EVENTS" || fail 'reconnect did not stop the interface first'
grep -F -q "up apnmodem1" "$TEST_EVENTS" || fail 'reconnect did not start the interface again'

printf '%s\n' 'TEST connect is retryable rather than successful when netifd never comes up'
TEST_IFACE_UP=
export TEST_IFACE_UP
timeout_status=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || timeout_status=$?
[ "$timeout_status" -eq 3 ] || \
	fail "a section that never came up exited $timeout_status instead of the retryable class 3"

printf '%s\n' 'TEST connection control refuses a modem bound to no cellular interface'
sh "$SCRIPT" deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || :
unowned_conn=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || unowned_conn=$?
[ "$unowned_conn" -eq 4 ] || fail "connect with no bound interface exited $unowned_conn instead of 4"

# Bearer control is ifup/ifdown, which the APN engine already performs on
# user-created interfaces during every reconcile. Refusing the verb while
# performing the action was the inconsistency 0.13.0 corrects; adoption is a
# separate decision and stays refused below.
printf '%s\n' 'TEST bearer control drives a user-created cellular interface'
provision_fixture
add_network_section usermade qmi /dev/cdc-wdm0
: >"$TEST_EVENTS"
TEST_IFACE_UP=usermade
export TEST_IFACE_UP
user_conn_out="$(sh "$SCRIPT" connect --modem "$PROV_MODEM")" || \
	fail 'connect refused a user-created cellular interface'
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["section"] == "usermade", d
assert d["action"] == "connect", d
assert d["state"] == "up", d
' "$user_conn_out" || fail 'connect did not report the user-created interface as up'
grep -F -x -q 'up usermade' "$TEST_EVENTS" || \
	fail 'connect did not ask netifd to start the user-created interface'
: >"$TEST_EVENTS"
sh "$SCRIPT" disconnect --modem "$PROV_MODEM" >/dev/null || \
	fail 'disconnect refused a user-created cellular interface'
grep -F -x -q 'down usermade' "$TEST_EVENTS" || \
	fail 'disconnect did not ask netifd to stop the user-created interface'
: >"$TEST_EVENTS"
sh "$SCRIPT" reconnect --modem "$PROV_MODEM" >/dev/null || \
	fail 'reconnect refused a user-created cellular interface'
grep -F -x -q 'down usermade' "$TEST_EVENTS" || \
	fail 'reconnect did not stop the user-created interface first'
grep -F -x -q 'up usermade' "$TEST_EVENTS" || \
	fail 'reconnect did not start the user-created interface again'

printf '%s\n' 'TEST configuration-changing verbs still refuse a user-created interface'
: >"$TEST_EVENTS"
: >"$TEST_UCI_WRITES"
user_deprov=0
sh "$SCRIPT" deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || user_deprov=$?
[ "$user_deprov" -eq 4 ] || fail "deprovision acted on a user-created interface (exit $user_deprov)"
user_prov=0
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null 2>&1 || user_prov=$?
[ "$user_prov" -eq 4 ] || fail "provision adopted a user-created interface (exit $user_prov)"
[ ! -s "$TEST_EVENTS" ] || fail 'a refused configuration verb still touched netifd'
[ ! -s "$TEST_UCI_WRITES" ] || fail 'a refused configuration verb still wrote UCI'
grep -F -x -q "network.usermade=interface" "$TEST_NETWORK_SECTIONS" || \
	fail 'a refused configuration verb removed the user-created section'

printf '%s\n' 'TEST the plan reports bearer control for a user-created interface and no provisioning'
user_plan="$(sh "$SCRIPT" provision-plan --modem "$PROV_MODEM" 2>/dev/null || :)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["can_provision"] is False, d
assert d["reason"] == "already_configured", d
assert d["can_control_bearer"] is True, d
assert d["connection_section"] == "usermade", d
assert d["connection_owned"] is False, d
' "$user_plan" || fail 'the plan misreported bearer control for a user-created interface'

printf '%s\n' 'TEST an ambiguous modem gets no bearer control at all'
add_network_section second qmi /dev/cdc-wdm0
: >"$TEST_EVENTS"
ambiguous_conn=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || ambiguous_conn=$?
[ "$ambiguous_conn" -eq 4 ] || \
	fail "connect acted on a modem claimed by two interfaces (exit $ambiguous_conn)"
[ ! -s "$TEST_EVENTS" ] || fail 'an ambiguous modem still had its interface touched'
ambiguous_plan="$(sh "$SCRIPT" provision-plan --modem "$PROV_MODEM" 2>/dev/null || :)"
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["can_control_bearer"] is False, d
assert d["connection_section"] == "", d
' "$ambiguous_plan" || fail 'the plan offered bearer control for an ambiguous modem'

printf '%s\n' 'TEST a non-cellular section bound to the same device is never driven'
provision_fixture
add_network_section wired static /dev/cdc-wdm0
: >"$TEST_EVENTS"
wired_conn=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || wired_conn=$?
[ "$wired_conn" -eq 4 ] || fail "connect drove a non-cellular section (exit $wired_conn)"
[ ! -s "$TEST_EVENTS" ] || fail 'a non-cellular section was still touched'

printf '%s\n' 'TEST a staged project-owned section is never started from connection control'
provision_fixture
sh "$SCRIPT" provision --modem "$PROV_MODEM" >/dev/null || fail 'provision failed'
add_section_option apnmodem1 disabled 1
: >"$TEST_EVENTS"
staged_conn=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || staged_conn=$?
[ "$staged_conn" -eq 4 ] || fail "connect started a staged section (exit $staged_conn)"
[ ! -s "$TEST_EVENTS" ] || fail 'connect touched netifd for a staged section'
staged_plan="$(sh "$SCRIPT" provision-plan --modem "$PROV_MODEM" 2>/dev/null || :)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["can_control_bearer"] is False, d' \
	"$staged_plan" || fail 'the plan offered to start a staged section'
# Stopping one is still allowed: a staged section cannot dial, so there is
# nothing unsafe about asking netifd to ensure it is down.
TEST_IFACE_UP=
export TEST_IFACE_UP
sh "$SCRIPT" disconnect --modem "$PROV_MODEM" >/dev/null || \
	fail 'disconnect refused a staged section'

TEST_IFACE_UP=
export TEST_IFACE_UP

printf '%s\n' 'TEST background provisioning is accepted and reaches a terminal result'
provision_fixture
bg_out="$(sh "$SCRIPT" action-start provision --modem "$PROV_MODEM")"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is True, d' "$bg_out" \
	|| fail 'action-start provision was not accepted'
bg_waited=0
while [ "$bg_waited" -lt 15 ]; do
	bg_state="$(sh "$SCRIPT" action-status --modem "$PROV_MODEM" | \
		python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')"
	case "$bg_state" in success|failed|blocked|retryable) break ;; esac
	bg_waited=$((bg_waited + 1))
	/bin/sleep 1
done
[ "$bg_state" = success ] || fail "background provisioning ended in state $bg_state"
[ "$(network_section_count apnmodem)" -eq 1 ] || fail 'background provisioning did not create the section'

printf '%s\n' 'TEST background deprovision removes what background provisioning created'
sh "$SCRIPT" action-start deprovision --modem "$PROV_MODEM" >/dev/null || fail 'action-start deprovision was rejected'
bg_waited=0
while [ "$bg_waited" -lt 15 ]; do
	bg_state="$(sh "$SCRIPT" action-status --modem "$PROV_MODEM" | \
		python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')"
	case "$bg_state" in success|failed|blocked|retryable) break ;; esac
	bg_waited=$((bg_waited + 1))
	/bin/sleep 1
done
[ "$bg_state" = success ] || fail "background deprovision ended in state $bg_state"
[ "$(network_section_count apnmodem)" -eq 0 ] || fail 'background deprovision left the section behind'

printf '%s\n' 'TEST an impossible background action is refused at launch, not at its terminal state'
provision_fixture
add_network_section taken qmi /dev/cdc-wdm0
refuse_status=0
sh "$SCRIPT" action-start provision --modem "$PROV_MODEM" >/dev/null 2>&1 || refuse_status=$?
[ "$refuse_status" -eq 4 ] || \
	fail "provisioning an already configured modem exited $refuse_status instead of 4 at launch"
refuse_status=0
sh "$SCRIPT" action-start deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || refuse_status=$?
[ "$refuse_status" -eq 4 ] || \
	fail "deprovisioning a section this package does not own exited $refuse_status instead of 4 at launch"

# The same launch, for the verb class that no longer depends on ownership: the
# precondition must accept it rather than refuse it at launch.
accept_status=0
sh "$SCRIPT" action-start connect --modem "$PROV_MODEM" >/dev/null 2>&1 || accept_status=$?
[ "$accept_status" -eq 0 ] || \
	fail "connect on a user-created interface exited $accept_status instead of being accepted at launch"
bg_waited=0
while [ "$bg_waited" -lt 15 ]; do
	bg_state="$(sh "$SCRIPT" action-status --modem "$PROV_MODEM" | \
		python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["state"])')"
	case "$bg_state" in success|failed|blocked|retryable) break ;; esac
	bg_waited=$((bg_waited + 1))
	/bin/sleep 1
done
case "$bg_state" in
	success|retryable) : ;;
	*) fail "the accepted connect ended in state $bg_state instead of a netifd outcome" ;;
esac

printf '%s\n' 'TEST the narrow control wrapper exposes every provisioning verb and nothing else'
provision_fixture
for verb in reset provision deprovision connect disconnect reconnect; do
	APN_AUTOCONFIG_MODEM_BIN="$MOCKBIN/record-modem-bin" sh "$CONTROL_SCRIPT" "$verb" "$PROV_MODEM" >/dev/null 2>&1 || :
	grep -F -q "action-start $verb --modem $PROV_MODEM" "$STATE/control-calls" || \
		fail "the control wrapper did not forward $verb as a background action"
done
for bad in provision-plan inventory status rescan reset-all 'reset;id' ''; do
	bad_status=0
	sh "$CONTROL_SCRIPT" "$bad" "$PROV_MODEM" >/dev/null 2>&1 || bad_status=$?
	[ "$bad_status" -eq 2 ] || fail "the control wrapper accepted the unlisted verb '$bad'"
done

printf '%s\n' 'TEST the control wrapper refuses an unsafe or oversized modem identity'
for bad_id in 'a b' 'a/../b' '$(id)' "$(awk 'BEGIN { while (i++ < 201) printf "a" }')"; do
	bad_status=0
	sh "$CONTROL_SCRIPT" reset "$bad_id" >/dev/null 2>&1 || bad_status=$?
	[ "$bad_status" -eq 2 ] || fail 'the control wrapper accepted an unsafe modem identity'
done
bad_status=0
sh "$CONTROL_SCRIPT" reset "$PROV_MODEM" extra >/dev/null 2>&1 || bad_status=$?
[ "$bad_status" -eq 2 ] || fail 'the control wrapper accepted a third argument'

printf '%s\n' 'TEST the query wrapper exposes provision-plan read-only and stays read-only'
provision_fixture
reset_network_config
plan_out="$(sh "$QUERY_SCRIPT" provision-plan "$PROV_MODEM")" || fail 'the query wrapper could not run provision-plan'
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["can_provision"] is True, d' "$plan_out" \
	|| fail 'provision-plan through the query wrapper did not report a provisionable modem'
uci_wrote_nothing || fail 'the read-only query wrapper wrote network configuration'
for bad in provision deprovision connect reset rescan; do
	bad_status=0
	sh "$QUERY_SCRIPT" "$bad" "$PROV_MODEM" >/dev/null 2>&1 || bad_status=$?
	[ "$bad_status" -eq 2 ] || fail "the read-only query wrapper accepted the mutating verb '$bad'"
done

printf '%s\n' 'TEST the narrow query wrapper rejects unlisted verbs and out-of-range arguments'
if "$QUERY_SCRIPT" inventory extra-arg >/dev/null 2>&1; then
	fail 'query wrapper accepted an extra argument'
fi
if "$QUERY_SCRIPT" status >/dev/null 2>&1; then
	fail 'query wrapper accepted status without --modem-equivalent argument'
fi
if "$QUERY_SCRIPT" reset --modem x >/dev/null 2>&1; then
	fail 'query wrapper must not expose the mutating reset verb'
fi

printf '%s\n' 'TEST the narrow control wrapper only exposes reset and requires a modem id'
if "$CONTROL_SCRIPT" reset >/dev/null 2>&1; then
	fail 'control wrapper accepted reset without --modem'
fi
if "$CONTROL_SCRIPT" inventory --modem x >/dev/null 2>&1; then
	fail 'control wrapper must not expose the read-only inventory verb'
fi

# ---- apn-autoconfig compatibility mapping (soft coupling) ----

printf '%s\n' 'TEST apn-autoconfig falls back to its inline reset path when apn-autoconfig-modem is absent from PATH'
CORE_MOCKBIN="$TESTROOT/core-bin"
mkdir -p "$CORE_MOCKBIN"
cat >"$CORE_MOCKBIN/uci" <<EOF
#!/bin/sh
[ "\${1:-}" = "-q" ] && shift
case "\$1:\$2" in
show:network) printf '%s\n' "network.wwan=interface" "network.wwan.proto='qmi'" ;;
get:apn-autoconfig.main.interface) printf '%s\n' wwan ;;
get:apn-autoconfig.main.modem_power_path) printf '%s\n' "$GPIO" ;;
get:network.wwan.proto) printf '%s\n' qmi ;;
*) exit 1 ;;
esac
EOF
chmod 0755 "$CORE_MOCKBIN/uci"
if command -v apn-autoconfig-modem >/dev/null 2>&1; then
	fail 'apn-autoconfig-modem must not be resolvable from the bare compatibility-check PATH'
fi
(PATH="$CORE_MOCKBIN:/usr/bin:/bin" command -v apn-autoconfig-modem >/dev/null 2>&1) \
	&& fail 'compatibility-check PATH unexpectedly resolves apn-autoconfig-modem'

printf '%s\n' 'TEST apn-autoconfig delegates power-cycle to apn-autoconfig-modem when resolve succeeds'
DELEGATE_MOCKBIN="$TESTROOT/delegate-bin"
mkdir -p "$DELEGATE_MOCKBIN"
: >"$STATE/delegate-calls"
cat >"$DELEGATE_MOCKBIN/apn-autoconfig-modem" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$STATE/delegate-calls"
case "\${1:-}" in
resolve) printf '%s\n' 'imei:delegated-modem'; exit 0 ;;
reset) exit 0 ;;
esac
exit 2
EOF
chmod 0755 "$DELEGATE_MOCKBIN/apn-autoconfig-modem"
[ -x "$DELEGATE_MOCKBIN/apn-autoconfig-modem" ] || fail 'delegate stub is not executable'
python3 -c '
import re, sys
text = open(sys.argv[1]).read()
assert "modem_reset_coordinator_modem_id" in text
assert "modem_reset_via_coordinator_cmd" in text
assert "apn-autoconfig-modem resolve --interface" in text
assert "apn-autoconfig-modem reset --modem" in text
' "$CORE_SCRIPT" || fail 'apn-autoconfig no longer contains the expected coordinator delegation hooks'

printf '%s\n' 'TEST no command leaves a scratch file behind in /tmp'
# Compares the exact set of scratch files, not their count: /tmp is shared, so a
# count is affected by anything else on the machine and by leftovers from an
# earlier run. Only a file that appears and stays is a leak.
#
# The fixtures never caught this because the names carry the PID: every run made
# its own, so nothing collided and nothing failed. LuCI polls provision-plan and
# status-json, which is how an open page grew /tmp without bound.
scratch_list() {
	ls /tmp/apn-autoconfig-modem.*.inventory /tmp/apn-autoconfig-modem.*.candidates \
		/tmp/apn-autoconfig-modem.*.mm-usb-paths 2>/dev/null | sort
}
scratch_list >"$STATE/scratch-before"
provision_fixture
for scratch_cmd in inventory-json rescan; do
	sh "$SCRIPT" "$scratch_cmd" >/dev/null 2>&1 || :
done
for scratch_cmd in provision-plan status-json action-status; do
	sh "$SCRIPT" "$scratch_cmd" --modem "$PROV_MODEM" >/dev/null 2>&1 || :
done
sh "$SCRIPT" resolve --interface wwan >/dev/null 2>&1 || :
scratch_list >"$STATE/scratch-after"
scratch_new="$(comm -13 "$STATE/scratch-before" "$STATE/scratch-after")"
[ -z "$scratch_new" ] || {
	printf 'leaked scratch files:\n%s\n' "$scratch_new" >&2
	fail 'a command left a scratch file behind in /tmp'
}

printf 'All modem-control tests passed.\n'
