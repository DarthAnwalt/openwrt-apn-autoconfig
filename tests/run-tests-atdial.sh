#!/bin/sh
set -eu

# Synthetic contract tests for apn-autoconfig-proto-atdial, per
# docs/atdial-contract-v1.md. Everything here is fixture-based: no hardware, no
# netifd, no SDK build.
#
# What these can and cannot judge is worth stating, because it decides how much
# weight the release may put on a green run. A fixture AT port answers instantly
# and correctly by construction, which is the case that never breaks. These
# tests exist for the decisions *around* the transport — which node is used, who
# is allowed to use it, what is refused, what is retried and what is restored —
# and the hardware gate exists for everything else.

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="$(CDPATH= cd -- /tmp && pwd -P)/apn-autoconfig-atdial-test.$$"
MOCKBIN="$TESTROOT/bin"
STATE="$TESTROOT/state"
HANDLER="$BASE/apn-autoconfig-proto-atdial/files/lib/netifd/proto/apn_atdial.sh"
LIB="$BASE/apn-autoconfig-proto-atdial/files/usr/share/apn-autoconfig-proto-atdial/atdial.sh"

cleanup() { rm -rf "$TESTROOT"; }
trap cleanup 0 HUP INT TERM

mkdir -p "$MOCKBIN" "$STATE" "$TESTROOT/sys/class/net" "$TESTROOT/sys/bus/usb/devices" \
	"$TESTROOT/lock" "$TESTROOT/scratch"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# ---- mocked environment ----

# The AT device. Replies come from a per-command fixture table so a test can
# make any single command fail, hang or answer differently without a new mock.
cat >"$MOCKBIN/sms_tool" <<'EOF'
#!/bin/sh
device=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-d) device="$2"; shift 2 ;;
		at) shift; break ;;
		*) shift ;;
	esac
done
command="$1"
printf '%s\t%s\n' "$device" "$command" >>"$TEST_AT_LOG"
behaviour="$(awk -F'\t' -v c="$command" '$1 == c { print $2; exit }' "$TEST_AT_REPLIES" 2>/dev/null)"
case "$behaviour" in
	HANG) exec /bin/sleep 30 ;;
	ERROR) printf 'ERROR\r\n'; exit 1 ;;
	'') printf 'OK\r\n'; exit 0 ;;
	*) printf '%s\r\n' "$behaviour" | tr '|' '\n'; printf 'OK\r\n'; exit 0 ;;
esac
EOF

# The modem package. Only the two read-only verbs the handler uses.
cat >"$MOCKBIN/apn-autoconfig-modem" <<'EOF'
#!/bin/sh
verb="$1"
shift
modem=""
while [ "$#" -gt 0 ]; do
	case "$1" in --modem) modem="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\t%s\n' "$verb" "$modem" >>"$TEST_MODEM_LOG"
case "$verb" in
	at-port)
		[ -n "${TEST_AT_PORT_EXIT:-}" ] && exit "$TEST_AT_PORT_EXIT"
		[ -n "${TEST_AT_PORT:-}" ] || exit 3
		printf '%s\n' "$TEST_AT_PORT"
	;;
	status-json)
		printf '{"version":"v1","modem_id":"%s","usb_path":"%s","owner_state":"%s"}\n' \
			"$modem" "${TEST_MODEM_USB_PATH:-}" "${TEST_OWNER_STATE:-none}"
	;;
	*) exit 2 ;;
esac
exit 0
EOF

cat >"$MOCKBIN/jsonfilter" <<'EOF'
#!/bin/sh
expression=""
while [ "$#" -gt 0 ]; do
	case "$1" in -e) expression="$2"; shift 2 ;; *) shift ;; esac
done
document="$(cat)"
key="${expression#@.}"
printf '%s' "$document" | sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p"
EOF

cat >"$MOCKBIN/modprobe" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >>"$TEST_MODPROBE_LOG"
# A driver bind that the fixture can arrange to happen, or not.
if [ -n "${TEST_MODPROBE_CREATES:-}" ]; then
	mkdir -p "$TEST_SYSFS/class/net/$TEST_MODPROBE_CREATES"
	mkdir -p "$TEST_SYSFS/bus/usb/devices/$TEST_MODPROBE_USB:1.0/net/$TEST_MODPROBE_CREATES"
fi
exit 0
EOF

cat >"$MOCKBIN/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_IP_LOG"
exit 0
EOF

cat >"$MOCKBIN/uci" <<'EOF'
#!/bin/sh
exit 1
EOF

cat >"$MOCKBIN/fw3" <<'EOF'
#!/bin/sh
printf '%s\n' "${TEST_FW_ZONE:-}"
exit 0
EOF

cat >"$MOCKBIN/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TEST_UBUS_LOG"
exit 0
EOF

cat >"$MOCKBIN/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0755 "$MOCKBIN"/*
PATH="$MOCKBIN:$PATH"
export PATH

export TEST_SYSFS="$TESTROOT/sys"
export TEST_AT_LOG="$STATE/at-log"
export TEST_AT_REPLIES="$STATE/at-replies"
export TEST_MODEM_LOG="$STATE/modem-log"
export TEST_MODPROBE_LOG="$STATE/modprobe-log"
export TEST_IP_LOG="$STATE/ip-log"
export TEST_UBUS_LOG="$STATE/ubus-log"

export APN_ATDIAL_SYSFS_ROOT="$TEST_SYSFS"
export APN_ATDIAL_SCRATCH_DIR="$TESTROOT/scratch"
export APN_ATDIAL_AT_PORT_LOCK_ROOT="$TESTROOT/lock/at-port"
export APN_ATDIAL_MODEM_BIN="$MOCKBIN/apn-autoconfig-modem"
export APN_ATDIAL_QUIRKS="$BASE/apn-autoconfig-proto-atdial/files/usr/share/apn-autoconfig-proto-atdial/quirks"
export APN_ATDIAL_LIB="$LIB"
export APN_ATDIAL_LOCK_WAIT=2
# The pacing sleep stays a no-op so the suite is fast, but the watchdog needs a
# real one: sharing the mock makes it fire before the command it bounds has
# started, and every AT read then reports a timeout. There is deliberately no
# `timeout` mock, because the reference router has no such executable and the
# watchdog is the branch that actually runs there.
export APN_ATDIAL_WATCHDOG_SLEEP=/bin/sleep
export APN_ATDIAL_AT_TIMEOUT=1

# ---- netifd stubs ----
#
# The handler is sourced with INCLUDE_ONLY set, which is the hook netifd's own
# handlers use so they can be read without a netifd around them.

PROTO_ERROR=""
PROTO_BLOCKED=0
PROTO_UPDATED=""
PROTO_ADDRESS=""
PROTO_ROUTES=""
PROTO_DNS=""

proto_notify_error() { PROTO_ERROR="$2"; }
proto_block_restart() { PROTO_BLOCKED=1; }
proto_init_update() { PROTO_UPDATED="$1"; }
proto_add_ipv4_address() { PROTO_ADDRESS="$1"; }
proto_add_ipv4_route() { PROTO_ROUTES="$PROTO_ROUTES$1/$2/$3/$5 "; }
proto_add_dns_server() { PROTO_DNS="$PROTO_DNS$1 "; }
proto_send_update() { PROTO_SENT=1; }
proto_add_dynamic_defaults() { :; }
proto_config_add_string() { :; }
proto_config_add_int() { :; }
proto_config_add_boolean() { :; }
proto_config_add_defaults() { :; }
proto_set_available() { :; }
add_protocol() { :; }
json_init() { :; }
json_add_string() { :; }
json_add_boolean() { :; }
json_add_int() { :; }
json_close_object() { :; }
json_dump() { printf '{}'; }

# The handler reads its options through json_get_vars. Each test sets TEST_OPT_*
# and this assigns them, which keeps the option names identical to the config.
json_get_vars() {
	for _name in "$@"; do
		eval "_value=\"\${TEST_OPT_$_name:-}\""
		eval "$_name=\"\$_value\""
	done
}

INCLUDE_ONLY=1
export INCLUDE_ONLY
# shellcheck disable=SC1090
. "$HANDLER"

# ---- fixture helpers ----

reset_case() {
	rm -rf "$TESTROOT/sys" "$TESTROOT/lock" "$TESTROOT/scratch"
	mkdir -p "$TESTROOT/sys/class/net" "$TESTROOT/sys/bus/usb/devices" \
		"$TESTROOT/lock" "$TESTROOT/scratch"
	: >"$TEST_AT_LOG"
	: >"$TEST_AT_REPLIES"
	: >"$TEST_MODEM_LOG"
	: >"$TEST_MODPROBE_LOG"
	: >"$TEST_IP_LOG"
	: >"$TEST_UBUS_LOG"
	PROTO_ERROR=""
	PROTO_BLOCKED=0
	PROTO_UPDATED=""
	PROTO_ADDRESS=""
	PROTO_ROUTES=""
	PROTO_DNS=""
	PROTO_SENT=0
	ATDIAL_ACTIVATED=0
	ATDIAL_LOCK_HELD=0
	ATDIAL_LOCK_PATH=""
	unset TEST_AT_PORT_EXIT TEST_MODPROBE_CREATES TEST_MODPROBE_USB 2>/dev/null || :
	TEST_AT_PORT=/dev/ttyUSB5
	TEST_OWNER_STATE=none
	TEST_MODEM_USB_PATH=2-1.3
	TEST_FW_ZONE=wan
	export TEST_AT_PORT TEST_OWNER_STATE TEST_MODEM_USB_PATH TEST_FW_ZONE
	# A sane default profile; a test overrides only what it is about.
	TEST_OPT_usbpath=2-1.3
	TEST_OPT_modem_id=imei:016177002734885
	TEST_OPT_device=""
	TEST_OPT_atport=""
	TEST_OPT_apn=internet
	TEST_OPT_username=""
	TEST_OPT_password=""
	TEST_OPT_auth=none
	TEST_OPT_pdptype=IPV4V6
	TEST_OPT_metric=1024
	TEST_OPT_allow_roaming=0
	export TEST_OPT_usbpath TEST_OPT_modem_id TEST_OPT_device TEST_OPT_atport \
		TEST_OPT_apn TEST_OPT_username TEST_OPT_password TEST_OPT_auth \
		TEST_OPT_pdptype TEST_OPT_metric TEST_OPT_allow_roaming
}

# add_usb_modem <usb-path> [interface-numbers...]
add_usb_modem() {
	_usb="$1"
	mkdir -p "$TEST_SYSFS/bus/usb/devices/$_usb"
	printf '%s\n' "${2:-0e8d}" >"$TEST_SYSFS/bus/usb/devices/$_usb/idVendor"
	printf '%s\n' "${3:-7127}" >"$TEST_SYSFS/bus/usb/devices/$_usb/idProduct"
	printf '%s\n' 7 >"$TEST_SYSFS/bus/usb/devices/$_usb/devnum"
}

# add_netdev <usb-path> <interface-number> <name>
add_netdev() {
	mkdir -p "$TEST_SYSFS/bus/usb/devices/$1:1.$2/net/$3"
	mkdir -p "$TEST_SYSFS/class/net/$3"
}

# Replaces any existing entry for that command rather than appending one. The
# mock takes the first match, so appending would silently leave the earlier
# reply in force and a test would assert against a fixture it did not set.
at_reply() {
	grep -v "^$1	" "$TEST_AT_REPLIES" >"$TEST_AT_REPLIES.new" 2>/dev/null || :
	printf '%s\t%s\n' "$1" "$2" >>"$TEST_AT_REPLIES.new"
	mv "$TEST_AT_REPLIES.new" "$TEST_AT_REPLIES"
}

# A modem that is registered at home and dials successfully.
happy_modem() {
	at_reply 'AT+CEREG?' '+CEREG: 0,1'
	at_reply 'AT+COPS?' '+COPS: 0,2,"26202",13'
	at_reply 'AT+CGPADDR=1' '+CGPADDR: 1,"10.9.146.175"'
	at_reply 'AT+CGCONTRDP=1' '+CGCONTRDP: 1,5,"internet","10.9.146.175.255.255.255.0","10.9.146.1","8.8.8.8","8.8.4.4"'
	at_reply 'AT+CGDCONT?' '+CGDCONT: 1,"IPV4V6","internet","",0,0'
	at_reply 'AT+CGACT?' '+CGACT: 0,0'
	at_reply 'AT+CGATT?' '+CGATT: 1'
}

at_sent() { grep -qF "	$1" "$TEST_AT_LOG"; }

# ---- tests ----

printf '%s\n' 'TEST a registered modem dials and publishes what the modem reported'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-no error reported}"
[ "$PROTO_UPDATED" = eth2 ] || fail "published on $PROTO_UPDATED instead of eth2"
[ "$PROTO_ADDRESS" = 10.9.146.175 ] || fail "published address $PROTO_ADDRESS"
[ "$PROTO_DNS" = "8.8.8.8 8.8.4.4 " ] || fail "published DNS '$PROTO_DNS'"
case "$PROTO_ROUTES" in *"0.0.0.0/0/10.9.146.1/1024"*) : ;; *) fail "published routes '$PROTO_ROUTES'" ;; esac
at_sent 'AT+CGACT=0,1' || fail 'the context was activated without being released first'
[ "$ATDIAL_LOCK_HELD" -eq 0 ] || fail 'the AT port lock was still held after a successful dial'

printf '%s\n' 'TEST a non-3GPP pdptype is normalised before it reaches CGDCONT'
# IPV4 is not a valid CGDCONT value. A modem that answers ERROR to it keeps the
# previous context, so the previous SIM APN survives every dial afterwards.
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
TEST_OPT_pdptype=IPV4
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-no error}"
at_sent 'AT+CGDCONT=1,"IP","internet"' || fail 'IPV4 was not normalised to IP'
grep -qF 'AT+CGDCONT=1,"IPV4"' "$TEST_AT_LOG" && fail 'the invalid IPV4 spelling reached the modem'

printf '%s\n' 'TEST the driver is loaded when the modem arrives with no network device'
# The measured hardware presents an RNDIS pair with nothing bound to it, so a
# handler that waits for a netdev waits forever.
reset_case
add_usb_modem 2-1.3
happy_modem
TEST_MODPROBE_CREATES=eth7
TEST_MODPROBE_USB=2-1.3
export TEST_MODPROBE_CREATES TEST_MODPROBE_USB
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-no error}"
grep -qx rndis_host "$TEST_MODPROBE_LOG" || fail 'rndis_host was never loaded'
[ "$PROTO_UPDATED" = eth7 ] || fail "published on $PROTO_UPDATED after the driver bound"

printf '%s\n' 'TEST no network device after loading the drivers is NO_NETDEV, and retries are not blocked'
reset_case
add_usb_modem 2-1.3
happy_modem
proto_apn_atdial_setup wwan_at && fail 'setup succeeded with no network device'
[ "$PROTO_ERROR" = NO_NETDEV ] || fail "reported $PROTO_ERROR instead of NO_NETDEV"
[ "$PROTO_BLOCKED" -eq 0 ] || fail 'a missing network device blocked restarts'

printf '%s\n' 'TEST a configured device that does not exist is NETDEV_MISSING, and blocks restarts'
# Without this netifd fails the interface and brings it straight back up, every
# few seconds, forever, explaining nothing.
reset_case
add_usb_modem 2-1.9
happy_modem
TEST_OPT_usbpath=""
TEST_OPT_device=eth9
proto_apn_atdial_setup wwan_at && fail 'setup succeeded with a device that does not exist'
[ "$PROTO_ERROR" = NETDEV_MISSING ] || fail "reported $PROTO_ERROR instead of NETDEV_MISSING"
[ "$PROTO_BLOCKED" -eq 1 ] || fail 'a nonexistent device did not block restarts'

printf '%s\n' 'TEST the lowest USB interface number wins, not the first glob match'
# ASCII sorts "1.10" before "1.6". On a device with three NCM interfaces the
# lexical answer is the wrong one, and on an Intel part the data channel is
# bound to the first — so the link comes up and carries nothing.
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 10 wwan2
add_netdev 2-1.3 6 wwan0
add_netdev 2-1.3 8 wwan1
happy_modem
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-no error}"
[ "$PROTO_UPDATED" = wwan0 ] || fail "selected $PROTO_UPDATED instead of wwan0 (interface 6)"

printf '%s\n' 'TEST ownership refused by the modem package is OWNER_CONFLICT, with no AT traffic'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
TEST_AT_PORT_EXIT=4
export TEST_AT_PORT_EXIT
proto_apn_atdial_setup wwan_at && fail 'setup proceeded while another owner held the modem'
[ "$PROTO_ERROR" = OWNER_CONFLICT ] || fail "reported $PROTO_ERROR instead of OWNER_CONFLICT"
[ ! -s "$TEST_AT_LOG" ] || fail 'a refused modem still received AT commands'

printf '%s\n' 'TEST ownership taken after the port lock is held aborts the dial'
# Validation before the lock has a time-of-check gap, and this modem class
# closes it the wrong way routinely: ModemManager publishes a freshly attached
# modem only once it has probed every port, so unowned-then-owned is ordinary.
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
TEST_OWNER_STATE=modemmanager
proto_apn_atdial_setup wwan_at && fail 'setup continued after ownership changed under it'
[ "$PROTO_ERROR" = OWNER_CONFLICT ] || fail "reported $PROTO_ERROR instead of OWNER_CONFLICT"
[ "$ATDIAL_LOCK_HELD" -eq 0 ] || fail 'the aborted dial kept the AT port lock'

printf '%s\n' 'TEST a port held by another component is refused, never used anyway'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
mkdir -p "$(dirname "$APN_ATDIAL_AT_PORT_LOCK_ROOT")"
printf '%s\n' "$$" >"$APN_ATDIAL_AT_PORT_LOCK_ROOT.ttyUSB5"
proto_apn_atdial_setup wwan_at && fail 'setup dialled through a port another component held'
[ "$PROTO_ERROR" = AT_PORT_BUSY ] || fail "reported $PROTO_ERROR instead of AT_PORT_BUSY"
[ ! -s "$TEST_AT_LOG" ] || fail 'a refused acquisition still wrote to the port'
[ -f "$APN_ATDIAL_AT_PORT_LOCK_ROOT.ttyUSB5" ] || fail "the refused caller removed another holder's lock"
rm -f "$APN_ATDIAL_AT_PORT_LOCK_ROOT.ttyUSB5"

printf '%s\n' 'TEST every registered stat dials, and every roaming one obeys the policy'
for reg_case in '1 home' '5 roam' '6 home' '7 roam' '9 home' '10 roam'; do
	reg_stat="${reg_case%% *}"
	reg_kind="${reg_case##* }"
	reset_case
	add_usb_modem 2-1.3
	add_netdev 2-1.3 0 eth2
	happy_modem
	at_reply 'AT+CEREG?' "+CEREG: 0,$reg_stat"
	if [ "$reg_kind" = home ]; then
		proto_apn_atdial_setup wwan_at || fail "stat $reg_stat did not dial: ${PROTO_ERROR:-none}"
		[ "$PROTO_ADDRESS" = 10.9.146.175 ] || fail "stat $reg_stat published no address"
	else
		proto_apn_atdial_setup wwan_at && fail "stat $reg_stat dialled while roaming was not allowed"
		[ "$PROTO_ERROR" = ROAMING_NOT_ALLOWED ] || \
			fail "stat $reg_stat reported $PROTO_ERROR instead of ROAMING_NOT_ALLOWED"
		[ "$PROTO_BLOCKED" -eq 1 ] || fail "stat $reg_stat did not block restarts"
	fi
done

printf '%s\n' 'TEST a roaming registration dials once roaming is allowed'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CEREG?' '+CEREG: 0,5'
TEST_OPT_allow_roaming=1
proto_apn_atdial_setup wwan_at || fail "roaming dial failed: ${PROTO_ERROR:-none}"
[ "$PROTO_ADDRESS" = 10.9.146.175 ] || fail 'the allowed roaming dial published no address'

printf '%s\n' 'TEST a refused registration is permanent and a missing one is not'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CEREG?' '+CEREG: 0,3'
proto_apn_atdial_setup wwan_at && fail 'setup dialled after the network refused registration'
[ "$PROTO_ERROR" = REGISTRATION_DENIED ] || fail "reported $PROTO_ERROR instead of REGISTRATION_DENIED"
[ "$PROTO_BLOCKED" -eq 1 ] || fail 'a refused registration did not block restarts'

reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CEREG?' '+CEREG: 0,2'
at_reply 'AT+CGREG?' '+CGREG: 0,2'
at_reply 'AT+CREG?' '+CREG: 0,2'
proto_apn_atdial_setup wwan_at && fail 'setup dialled without a network'
[ "$PROTO_ERROR" = NOT_REGISTERED ] || fail "reported $PROTO_ERROR instead of NOT_REGISTERED"
[ "$PROTO_BLOCKED" -eq 0 ] || fail 'a temporary lack of signal blocked restarts'

printf '%s\n' 'TEST a deregistered modem is pushed back to automatic selection once'
# At +COPS mode 2 the modem does not look for a network at all, and restarting
# the interface does not change that. The trigger is the mode, not a stat code,
# because the stat a deregistered modem reports varies by device.
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CEREG?' '+CEREG: 0,4'
at_reply 'AT+CGREG?' '+CGREG: 0,4'
at_reply 'AT+CREG?' '+CREG: 0,4'
at_reply 'AT+COPS?' '+COPS: 2'
proto_apn_atdial_setup wwan_at && fail 'a deregistered modem reported success'
[ "$(grep -cF 'AT+COPS=0' "$TEST_AT_LOG")" = 1 ] || \
	fail "automatic selection was re-enabled $(grep -cF 'AT+COPS=0' "$TEST_AT_LOG") times, expected once"

printf '%s\n' 'TEST a manual operator choice is never overridden'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CEREG?' '+CEREG: 0,0'
at_reply 'AT+CGREG?' '+CGREG: 0,0'
at_reply 'AT+CREG?' '+CREG: 0,0'
at_reply 'AT+COPS?' '+COPS: 1,2,"26203",7'
proto_apn_atdial_setup wwan_at && fail 'setup reported success with no registration'
grep -qF 'AT+COPS=0' "$TEST_AT_LOG" && fail "a manual operator selection was overridden"

printf '%s\n' 'TEST the PDP-type fallback fires only after a failure'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
grep -qF 'AT+CGDCONT=1,"IP","internet"' "$TEST_AT_LOG" && \
	fail 'the complementary PDP type was tried even though the first attempt worked'

reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CGPADDR=1' '+CGPADDR: 1,"0.0.0.0"'
proto_apn_atdial_setup wwan_at && fail 'setup reported success with no address'
[ "$PROTO_ERROR" = NO_IP_ADDRESS ] || fail "reported $PROTO_ERROR instead of NO_IP_ADDRESS"
[ "$PROTO_BLOCKED" -eq 1 ] || fail 'a context that never activated did not block restarts'
grep -qF 'AT+CGDCONT=1,"IP","internet"' "$TEST_AT_LOG" || \
	fail 'the complementary PDP type was never tried after the configured one failed'

printf '%s\n' 'TEST authentication is written on every cold dial, and none is written explicitly'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
TEST_OPT_auth=chap
TEST_OPT_username=user
TEST_OPT_password=secret
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
at_sent 'AT+CGAUTH=1,2,"user","secret"' || fail 'CHAP authentication was never sent'

reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
at_sent 'AT+CGAUTH=1,0' || \
	fail 'a profile without credentials did not clear the previous ones'

printf '%s\n' 'TEST a profile field that could compose a second AT command is refused'
# The administrator already has root, so this is not a privilege boundary. It is
# the difference between a clear refusal and a malformed command whose failure
# points nowhere near its cause.
for hostile in 'inter"net' "$(printf 'inter\rnet')"; do
	reset_case
	add_usb_modem 2-1.3
	add_netdev 2-1.3 0 eth2
	happy_modem
	TEST_OPT_apn="$hostile"
	proto_apn_atdial_setup wwan_at && fail 'a profile field with a quote or CR was accepted'
	[ ! -s "$TEST_AT_LOG" ] || fail 'a rejected profile field still reached the modem'
done

printf '%s\n' 'TEST a live context is reused only when everything about it matches'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CGACT?' '+CGACT: 1,1'
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
grep -qF 'AT+CGACT=1,1' "$TEST_AT_LOG" && fail 'a matching live context was re-dialled anyway'
[ "$PROTO_ADDRESS" = 10.9.146.175 ] || fail 'the reused context published no address'

for mismatch in apn pdp attach; do
	reset_case
	add_usb_modem 2-1.3
	add_netdev 2-1.3 0 eth2
	happy_modem
	at_reply 'AT+CGACT?' '+CGACT: 1,1'
	case "$mismatch" in
		# The previous SIM's APN, which the modem re-activates by itself at boot.
		apn) at_reply 'AT+CGDCONT?' '+CGDCONT: 1,"IPV4V6","old.operator","",0,0' ;;
		# No modem upgrades a context in place, so reuse would mean IPv6 never appears.
		pdp) at_reply 'AT+CGDCONT?' '+CGDCONT: 1,"IP","internet","",0,0' ;;
		# An active context on a detached modem: address reported, nothing carried.
		attach) at_reply 'AT+CGATT?' '+CGATT: 0' ;;
	esac
	proto_apn_atdial_setup wwan_at || fail "setup failed for $mismatch: ${PROTO_ERROR:-none}"
	grep -qF 'AT+CGACT=1,1' "$TEST_AT_LOG" || \
		fail "a stale context ($mismatch) was reused instead of dialled cold"
done

printf '%s\n' 'TEST IPv6 is a dynamic child, and only when the live context is v6-capable'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
grep -qF 'add_dynamic' "$TEST_UBUS_LOG" || fail 'no dhcpv6 child was started for a dual-stack context'

reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
at_reply 'AT+CGDCONT?' '+CGDCONT: 1,"IP","internet","",0,0'
TEST_OPT_pdptype=IP
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
grep -qF 'add_dynamic' "$TEST_UBUS_LOG" && fail 'a dhcpv6 child was started for an IPv4-only context'

printf '%s\n' 'TEST teardown releases the context rather than leaving a bearer netifd does not own'
reset_case
add_usb_modem 2-1.3
add_netdev 2-1.3 0 eth2
happy_modem
proto_apn_atdial_teardown wwan_at
at_sent 'AT+CGACT=0,1' || fail 'teardown left the PDP context active'
[ "$ATDIAL_LOCK_HELD" -eq 0 ] || fail 'teardown kept the AT port lock'

printf '%s\n' 'TEST a stale usbpath is re-resolved from the modem identity'
reset_case
add_usb_modem 2-1.7
add_netdev 2-1.7 0 eth3
happy_modem
TEST_OPT_usbpath=2-1.3
TEST_MODEM_USB_PATH=2-1.7
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
[ "$PROTO_UPDATED" = eth3 ] || fail "published on $PROTO_UPDATED after the modem moved sockets"

printf '%s\n' 'TEST a modem with no quirk entry gets the standard path and no vendor commands'
# The table's whole rule. A device nobody has driven gets nothing, so it fails
# visibly rather than misbehaving on commands invented for it.
reset_case
add_usb_modem 2-1.3 0e8d 7127
add_netdev 2-1.3 0 eth2
happy_modem
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
for unexpected in 'AT+XDNS=1,1' 'AT+XDATACHANNEL' 'AT+CGDATA' 'AT+XDNS?'; do
	grep -qF "$unexpected" "$TEST_AT_LOG" && \
		fail "an untested modem was sent the vendor command $unexpected"
done
grep -qF 'arp off' "$TEST_IP_LOG" && fail 'an untested modem had ARP disabled'

printf '%s\n' 'TEST an Intel XMM device gets the data channel, the vendor DNS and an on-link no-ARP route'
reset_case
add_usb_modem 2-1.3 8087 095a
add_netdev 2-1.3 6 wwan0
happy_modem
at_reply 'AT+CGMM' 'L860-GL'
at_reply 'AT+XDNS?' '+XDNS: 1,"10.1.1.1","10.1.1.2"'
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
at_sent 'AT+XDNS=1,1' || fail 'the vendor DNS report was never enabled'
at_sent 'AT+XDATACHANNEL=1,1,"/USBCDC/0","/USBHS/NCM/0",2,1' || \
	fail 'the NCM data channel was never bound to the context'
at_sent 'AT+CGDATA="M-RAW_IP",1' || fail 'data was never started on the bound channel'
[ "$PROTO_DNS" = "10.1.1.1 10.1.1.2 " ] || \
	fail "DNS came from CGCONTRDP instead of the vendor query: '$PROTO_DNS'"
grep -qF 'arp off' "$TEST_IP_LOG" || fail 'ARP was left enabled on a link that does not answer it'
case "$PROTO_ROUTES" in
	*"0.0.0.0/0//1024"*) : ;;
	*) fail "the XMM route was not on-link: '$PROTO_ROUTES'" ;;
esac

printf '%s\n' 'TEST the data channel is bound only after an address exists'
# Binding before there is a context to bind to is the ordering that silently
# produces a link carrying nothing.
reset_case
add_usb_modem 2-1.3 8087 095a
add_netdev 2-1.3 6 wwan0
happy_modem
at_reply 'AT+CGMM' 'L860-GL'
awk -F'\t' '{ print $2 }' "$TEST_AT_LOG" >"$STATE/order-before" 2>/dev/null || :
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
address_line="$(grep -n 'AT+CGPADDR=1' "$TEST_AT_LOG" | tail -1 | cut -d: -f1)"
channel_line="$(grep -n 'AT+XDATACHANNEL' "$TEST_AT_LOG" | head -1 | cut -d: -f1)"
[ -n "$address_line" ] && [ -n "$channel_line" ] || fail 'the ordering could not be observed'
[ "$channel_line" -gt "$address_line" ] || \
	fail 'the data channel was bound before an address existed'

printf '%s\n' 'TEST the second Intel product id resolves the same quirks'
reset_case
add_usb_modem 2-1.3 8087 07f9
add_netdev 2-1.3 6 wwan0
happy_modem
at_reply 'AT+CGMM' 'L860-GL'
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
at_sent 'AT+XDATACHANNEL=1,1,"/USBCDC/0","/USBHS/NCM/0",2,1' || \
	fail 'the second Intel product id did not resolve its quirks'

printf '%s\n' 'TEST an Intel vendor id with an unlisted product gets nothing'
# vendor_id alone is not a licence: the table lists products that were reported,
# and an Intel part nobody has driven is still an untested modem.
reset_case
add_usb_modem 2-1.3 8087 dead
add_netdev 2-1.3 6 wwan0
happy_modem
at_reply 'AT+CGMM' 'SOMETHING-ELSE'
proto_apn_atdial_setup wwan_at || fail "setup failed: ${PROTO_ERROR:-none}"
grep -qF 'AT+XDATACHANNEL' "$TEST_AT_LOG" && \
	fail 'an unlisted Intel product was given the XMM data channel'

printf '%s\n' 'All AT-dial protocol tests passed.'
