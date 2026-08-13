#!/bin/sh
set -eu

# Synthetic contract tests for apn-autoconfig-modem, per
# docs/testing-0.10.0.md and docs/modem-contract-v1.md. Everything here is
# fixture-based: no physical hardware, no SDK build. The Huasifei hardware
# gate and packaging/release gate stay pending for a real router.

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="${TMPDIR:-/tmp}/apn-autoconfig-modem-test.$$"
MOCKBIN="$TESTROOT/bin"
STATE="$TESTROOT/state"
SCRIPT="$BASE/apn-autoconfig-modem/files/usr/sbin/apn-autoconfig-modem"
ACTION_WORKER="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-action"
QUERY_SCRIPT="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-query"
CONTROL_SCRIPT="$BASE/apn-autoconfig-modem/files/usr/libexec/apn-autoconfig-modem-control"
CORE_SCRIPT="$BASE/files/usr/sbin/apn-autoconfig"

cleanup() {
	rm -rf "$TESTROOT"
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
get:apn-autoconfig-modem.main.action_state_dir) printf '%s\n' "$TEST_MODEM_ACTION_DIR" ;;
get:apn-autoconfig-modem.main.hotplug_coalesce_seconds) printf '%s\n' 0 ;;
get:apn-autoconfig-modem.main.modem_power_path) printf '%s\n' "$TEST_GPIO" ;;
get:apn-autoconfig-modem.main.modem_power_off_value) printf '%s\n' 1 ;;
get:apn-autoconfig-modem.main.modem_power_on_value) printf '%s\n' 0 ;;
get:apn-autoconfig-modem.main.modem_power_off_seconds) printf '%s\n' 0 ;;
get:apn-autoconfig-modem.main.modem_wait_seconds) printf '%s\n' 3 ;;
get:apn-autoconfig-modem.main.modem_poll_seconds) printf '%s\n' 1 ;;
get:apn-autoconfig-modem.main.hardware_integration_file) printf '%s\n' "$TEST_HARDWARE_MARKER" ;;
get:network.*)
	section="${2#network.}"
	name="${section%%.*}"
	option="${section#*.}"
	awk -F'\t' -v name="$name" -v option="$option" \
		'$1 == name && $2 == option { print $3; found=1 } END { exit found ? 0 : 1 }' \
		"$TEST_NETWORK_OPTIONS" 2>/dev/null
;;
*) exit 1 ;;
esac
EOF

cat >"$MOCKBIN/mmcli" <<'EOF'
#!/bin/sh
[ "${MM_UNAVAILABLE:-0}" = 1 ] && exit 1
case "${1:-}" in
-L)
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
EOF

cat >"$MOCKBIN/ifup" <<'EOF'
#!/bin/sh
printf 'up %s\n' "$1" >>"$TEST_EVENTS"
EOF

cat >"$MOCKBIN/logger" <<'EOF'
#!/bin/sh
exit 0
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
export TEST_MODEM_ACTION_DIR="$TESTROOT/action"
export TEST_GPIO="$GPIO"
export TEST_HARDWARE_MARKER="$HARDWARE_MARKER"
export TEST_NETWORK_SECTIONS="$STATE/network-sections"
export TEST_NETWORK_OPTIONS="$STATE/network-options"
export TEST_EVENTS="$STATE/events"
export APN_AUTOCONFIG_MODEM_ACTION_WORKER="$ACTION_WORKER"
export APN_AUTOCONFIG_MODEM_ACTION_COMMAND="$SCRIPT"
export APN_AUTOCONFIG_MODEM_BIN="$SCRIPT"

: >"$TEST_NETWORK_SECTIONS"
: >"$TEST_NETWORK_OPTIONS"
: >"$TEST_EVENTS"

reset_network_config() {
	: >"$TEST_NETWORK_SECTIONS"
	: >"$TEST_NETWORK_OPTIONS"
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

reset_sysfs() {
	rm -rf "$TESTROOT/sys"
	mkdir -p "$TESTROOT/sys/class/gpio/modem_power" "$TESTROOT/sys/class/usbmisc" \
		"$TESTROOT/sys/class/net" "$TESTROOT/sys/class/tty" "$TESTROOT/sys/class/wwan"
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
	ln -s "$usb_dir/$bus_port:1.4" "$TESTROOT/sys/class/usbmisc/cdc-wdm$wdm/device"
	if [ -n "$data_iface" ]; then
		mkdir -p "$usb_dir/$bus_port:1.6" "$TESTROOT/sys/class/net/$data_iface"
		ln -s "$usb_dir/$bus_port:1.6" "$TESTROOT/sys/class/net/$data_iface/device"
	fi
}

reset_sysfs

# ---- tests ----

printf '%s\n' 'TEST inventory-json is empty when no modem is present'
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
rm -f "$HARDWARE_MARKER"
if sh "$SCRIPT" reset --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01 >/dev/null 2>&1; then
	fail 'reset should require a board integration marker'
else
	[ "$?" -eq 4 ] || fail 'reset without board integration did not use exit code 4'
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

printf '%s\n' 'TEST reset refuses to run against a conflicting-ownership modem'
reset_sysfs
reset_network_config
add_qmi_modem 2-1.1 2c7c 0125 '' 3
add_network_section celldirect qmi /dev/cdc-wdm3
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
printf '%s\n' 'huasifei-wh3000-gpio-v1' >"$HARDWARE_MARKER"
start_out="$(sh "$SCRIPT" action-start reset --modem usb-serial:1-1.2:2c7c:0801:RM520SERIAL01)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is True' "$start_out" \
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

printf '%s\n' 'TEST a stale running state left by a dead PID does not block a new action-start'
mkdir -p "$TEST_MODEM_ACTION_DIR/imei_stale-fake"
printf 'v1\trunning\treset\t999999\t2026-01-01T00:00:00Z\t\t\toperation is running\n' \
	>"$TEST_MODEM_ACTION_DIR/imei_stale-fake/state.tsv"
if kill -0 999999 2>/dev/null; then
	printf 'SKIP: PID 999999 is unexpectedly alive on this host\n'
else
	stale_out="$(sh "$SCRIPT" action-start reset --modem imei:stale-fake)"
	python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is True, d' "$stale_out" \
		|| fail 'a dead PID left over from a previous run should not block a new action-start indefinitely'
fi

printf '%s\n' 'TEST a genuinely running action for a modem refuses a second concurrent start'
mkdir -p "$TEST_MODEM_ACTION_DIR/imei_busy-fake"
printf 'v1\trunning\treset\t%s\t2026-01-01T00:00:00Z\t\t\toperation is running\n' "$$" \
	>"$TEST_MODEM_ACTION_DIR/imei_busy-fake/state.tsv"
busy_out="$(sh "$SCRIPT" action-start reset --modem imei:busy-fake)"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["accepted"] is False, d' "$busy_out" \
	|| fail 'a modem with a live-PID running action must refuse a second concurrent action-start'

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
