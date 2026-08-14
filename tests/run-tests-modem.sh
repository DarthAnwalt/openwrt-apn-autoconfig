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
get:apn-autoconfig-modem.main.modem_power_path) printf '%s\n' "$TEST_GPIO" ;;
get:apn-autoconfig-modem.main.modem_power_off_value) printf '%s\n' 1 ;;
get:apn-autoconfig-modem.main.modem_power_on_value) printf '%s\n' 0 ;;
get:apn-autoconfig-modem.main.modem_power_off_seconds) printf '%s\n' "${TEST_MODEM_POWER_OFF_SECONDS:-1}" ;;
get:apn-autoconfig-modem.main.modem_wait_seconds) printf '%s\n' 3 ;;
get:apn-autoconfig-modem.main.modem_poll_seconds) printf '%s\n' 1 ;;
get:apn-autoconfig-modem.main.connect_wait_seconds) printf '%s\n' "${TEST_CONNECT_WAIT_SECONDS:-2}" ;;
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
	printf '%s\n' \
		"modem.generic.device : ${MM_DEVICE:---}" \
		"modem.generic.physdev : ${MM_PHYSDEV:---}" \
		"modem.generic.equipment-identifier : ${MM_IMEI:---}"
	exit 0
;;
esac
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

cat >"$MOCKBIN/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF

chmod 0755 "$MOCKBIN"/*
export PATH="$MOCKBIN:/usr/bin:/bin"
export TEST_SYSFS="$TESTROOT/sys"
export TEST_MODEM_STATE_DIR="$TESTROOT/run"
export TEST_MODEM_LOCK_ROOT="$TESTROOT/lock/apn-autoconfig-modem"
export TEST_APN_LOCK_DIR="$TESTROOT/lock/apn-autoconfig.lock"
export TEST_QMI_IDENTITY_LOCK_ROOT="$TESTROOT/lock/apn-autoconfig-qmi-identity"
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
export TEST_STATE="$STATE"
export APN_AUTOCONFIG_MODEM_ACTION_WORKER="$ACTION_WORKER"
export APN_AUTOCONFIG_MODEM_ACTION_COMMAND="$SCRIPT"
export APN_AUTOCONFIG_MODEM_BIN="$SCRIPT"

: >"$TEST_NETWORK_SECTIONS"
: >"$TEST_NETWORK_OPTIONS"
: >"$TEST_EVENTS"
: >"$TEST_UQMI_CALLS"

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
assert m["implementation_state"] == "experimental", m
assert m["validation_state"] == "synthetic", m
assert m["hardware_validated"] is False, m
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
' "$out" || fail 'inventory-only MBIM/AT classification is wrong'

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

printf '%s\n' 'TEST an AT-only modem with multiple ports remains ambiguous without role evidence'
reset_sysfs
add_at_modem 3-1.4 2c7c 0801 ATMULTIPORT 1
add_at_modem 3-1.4 2c7c 0801 ATMULTIPORT 2
out="$(sh "$SCRIPT" inventory-json)"
python3 -c '
import json, sys
m = json.loads(sys.argv[1])["modems"][0]
assert m["protocol"] == "at", m
assert m["ambiguous"] is True, m
assert m["owner_state"] == "conflicting", m
assert not m["at_device"], m
' "$out" || fail 'AT-only multi-port modem selected a port without role evidence'

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

printf '%s\n' 'TEST provision refuses a second section for an already provisioned modem'
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

printf '%s\n' 'TEST connection control refuses a modem with no project-owned section'
sh "$SCRIPT" deprovision --modem "$PROV_MODEM" >/dev/null 2>&1 || :
unowned_conn=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || unowned_conn=$?
[ "$unowned_conn" -eq 4 ] || fail "connect without a project-owned section exited $unowned_conn instead of 4"

printf '%s\n' 'TEST connection control never drives a user-created interface'
provision_fixture
add_network_section usermade qmi /dev/cdc-wdm0
: >"$TEST_EVENTS"
usercontrol=0
sh "$SCRIPT" connect --modem "$PROV_MODEM" >/dev/null 2>&1 || usercontrol=$?
[ "$usercontrol" -eq 4 ] || fail "connect adopted a user-created interface (exit $usercontrol)"
[ ! -s "$TEST_EVENTS" ] || fail 'connect touched netifd for an interface it does not own'
TEST_IFACE_UP=
export TEST_IFACE_UP

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

printf 'All modem-control tests passed.\n'
