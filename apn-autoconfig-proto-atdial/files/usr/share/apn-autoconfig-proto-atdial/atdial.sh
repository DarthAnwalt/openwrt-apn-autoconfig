#!/bin/sh

# Bounded AT transport, shared port lock and sysfs helpers for the apn_atdial
# netifd protocol. See docs/atdial-contract-v1.md.
#
# This is a library to be sourced, not an executable, and that is a decision
# rather than a packaging accident. The dial holds the AT port lock across
# fourteen commands, so a one-shot helper would have to acquire and release it
# per command and could not hold it across the sequence at all. Sourcing also
# means there is no installed executable anywhere on the system that accepts an
# AT command as an argument: every AT string in this project is a literal in
# code, and adding a general-purpose gateway would quietly undo that.
#
# Every name here is prefixed `atdial_`/`ATDIAL_`. The handler runs inside a
# shell that has already sourced /lib/functions.sh and netifd-proto.sh, and a
# collision with either would be very hard to diagnose from a failing dial.

ATDIAL_SYSFS_ROOT="${APN_ATDIAL_SYSFS_ROOT:-/sys}"
ATDIAL_SMS_TOOL="${APN_ATDIAL_SMS_TOOL:-sms_tool}"
ATDIAL_TIMEOUT="${APN_ATDIAL_TIMEOUT:-timeout}"
ATDIAL_SLEEP="${APN_ATDIAL_SLEEP:-sleep}"
# The watchdog gets its own, and only so the fixtures can give that one path a
# real sleep while the rest of the suite keeps an instant mock. Sharing them
# makes an instant mock fire the watchdog before the command it is bounding has
# started, so every AT read reports a timeout and nothing under test is what
# fails. apn-autoconfig-modem carries the same split for the same reason.
ATDIAL_WATCHDOG_SLEEP="${APN_ATDIAL_WATCHDOG_SLEEP:-$ATDIAL_SLEEP}"
ATDIAL_MODPROBE="${APN_ATDIAL_MODPROBE:-modprobe}"
ATDIAL_MODEM_BIN="${APN_ATDIAL_MODEM_BIN:-/usr/sbin/apn-autoconfig-modem}"
ATDIAL_SCRATCH_DIR="${APN_ATDIAL_SCRATCH_DIR:-/tmp}"
ATDIAL_QUIRKS="${APN_ATDIAL_QUIRKS:-/usr/share/apn-autoconfig-proto-atdial/quirks}"

# Per-command bound. The reference router has no `timeout` executable at all,
# so the watchdog below is the branch that actually runs there.
ATDIAL_AT_TIMEOUT="${APN_ATDIAL_AT_TIMEOUT:-5}"
# How long to wait for the shared port lock before refusing. Refusing is the
# only other option: proceeding unlocked is never one.
ATDIAL_LOCK_WAIT="${APN_ATDIAL_LOCK_WAIT:-20}"

ATDIAL_REPLY=""
ATDIAL_TIMED_OUT=0
ATDIAL_LOCK_PATH=""
ATDIAL_LOCK_HELD=0
ATDIAL_CHILD_PID=""
ATDIAL_WATCHDOG_PID=""
ATDIAL_OUT_FILE=""
ATDIAL_MARKER_FILE=""

# ---- configuration ----

atdial_uci_get() {
	command -v uci >/dev/null 2>&1 || return 1
	uci -q get "$1" 2>/dev/null
}

# The AT port lock namespace is shared with apn-autoconfig-modem and
# apn-autoconfig-qmi. All three resolve it in the same order — env, then the
# UCI option apn-autoconfig-modem owns, then the built-in default — because a
# lock the packages disagree about excludes nothing while still reporting
# success to each of them.
atdial_resolve_lock_root() {
	ATDIAL_LOCK_ROOT="${APN_ATDIAL_AT_PORT_LOCK_ROOT:-${APN_AUTOCONFIG_AT_PORT_LOCK_ROOT:-}}"
	[ -n "$ATDIAL_LOCK_ROOT" ] || \
		ATDIAL_LOCK_ROOT="$(atdial_uci_get apn-autoconfig-modem.main.at_port_lock_root || :)"
	case "$ATDIAL_LOCK_ROOT" in
		/|*/../*|*/..|'') ATDIAL_LOCK_ROOT="/var/lock/apn-autoconfig-at-port" ;;
		/*) : ;;
		*) ATDIAL_LOCK_ROOT="/var/lock/apn-autoconfig-at-port" ;;
	esac
}
atdial_resolve_lock_root

# ---- value validation ----

# A value that reaches an AT command string. The quote and the carriage return
# are the two that matter: a quote closes the argument early and a CR ends the
# command line, so either would let an APN or a password compose a second
# command. The router administrator already has root, so this is not a
# privilege boundary — it is the difference between a clear refusal and a
# malformed command whose failure points nowhere near its cause.
ATDIAL_CR="$(printf '\r')"
ATDIAL_TAB="$(printf '\t')"

atdial_safe_value() {
	case "$1" in
		*'"'*|*'\'*) return 1 ;;
		*"$ATDIAL_CR"*|*"$ATDIAL_TAB"*) return 1 ;;
	esac
	# A newline cannot be tested with a pattern built from command substitution,
	# because that strips trailing newlines and leaves the empty string — which
	# as a shell pattern matches everything, so every value would be rejected.
	# Count records instead, the same way the APN engine does.
	[ "$(printf '%s' "$1" | awk 'END { print NR + 0 }')" -le 1 ] || return 1
	[ "${#1}" -le 128 ] || return 1
	return 0
}

atdial_valid_device_name() {
	case "$1" in
		ttyUSB[0-9]*|ttyACM[0-9]*) : ;;
		*) return 1 ;;
	esac
	case "${1#tty???}" in ''|*[!0-9]*) return 1 ;; esac
	return 0
}

# A USB topology path as it appears under /sys/bus/usb/devices, e.g. 2-1.3.
atdial_valid_usb_path() {
	case "$1" in
		''|*/*|*..*) return 1 ;;
		*[!0-9A-Za-z.:_-]*) return 1 ;;
	esac
	return 0
}

# ---- bounded execution ----

atdial_process_alive() {
	case "$1" in ''|*[!0-9]*|0) return 1 ;; esac
	kill -0 "$1" 2>/dev/null
}

# Runs a command with an outer bound, writing stdout to $ATDIAL_OUT_FILE.
# Returns 124 on expiry, otherwise the command's own status.
atdial_run_bounded() {
	atdial_bound="$1"
	shift
	ATDIAL_TIMED_OUT=0
	if command -v "$ATDIAL_TIMEOUT" >/dev/null 2>&1; then
		atdial_status=0
		"$ATDIAL_TIMEOUT" "$atdial_bound" "$@" >"$ATDIAL_OUT_FILE" 2>/dev/null || atdial_status=$?
		[ "$atdial_status" -ne 124 ] || ATDIAL_TIMED_OUT=1
		return "$atdial_status"
	fi
	# The timeout is carried by a marker file rather than by the child's exit
	# status, because a child killed by the watchdog reports 143 exactly like a
	# child killed by an external TERM — and the caller has to tell "this port
	# never answered" from "the modem said ERROR".
	rm -f "$ATDIAL_MARKER_FILE" 2>/dev/null || :
	"$@" >"$ATDIAL_OUT_FILE" 2>/dev/null &
	ATDIAL_CHILD_PID=$!
	(
		"$ATDIAL_WATCHDOG_SLEEP" "$atdial_bound"
		: >"$ATDIAL_MARKER_FILE" 2>/dev/null || :
		kill -TERM "$ATDIAL_CHILD_PID" 2>/dev/null || exit 0
		"$ATDIAL_WATCHDOG_SLEEP" 1
		kill -9 "$ATDIAL_CHILD_PID" 2>/dev/null || :
	) >/dev/null 2>&1 &
	ATDIAL_WATCHDOG_PID=$!
	atdial_status=0
	# The shell announces a killed background job on its own stderr when it is
	# reaped. On a timeout that is expected rather than news, and netifd would
	# otherwise carry "Terminated" into the system log on every silent port.
	wait "$ATDIAL_CHILD_PID" 2>/dev/null || atdial_status=$?
	ATDIAL_CHILD_PID=""
	kill -TERM "$ATDIAL_WATCHDOG_PID" 2>/dev/null || :
	wait "$ATDIAL_WATCHDOG_PID" 2>/dev/null || :
	ATDIAL_WATCHDOG_PID=""
	if [ -e "$ATDIAL_MARKER_FILE" ]; then
		rm -f "$ATDIAL_MARKER_FILE" 2>/dev/null || :
		ATDIAL_TIMED_OUT=1
		return 124
	fi
	return "$atdial_status"
}

# Terminates and reaps whatever the bounded runner still has outstanding. The
# dial arms this before its first command, so an interrupted bring-up never
# leaves a child holding the serial port open.
atdial_reap() {
	[ -z "$ATDIAL_CHILD_PID" ] || {
		kill -TERM "$ATDIAL_CHILD_PID" 2>/dev/null || :
		"$ATDIAL_WATCHDOG_SLEEP" 1
		kill -9 "$ATDIAL_CHILD_PID" 2>/dev/null || :
		wait "$ATDIAL_CHILD_PID" 2>/dev/null || :
		ATDIAL_CHILD_PID=""
	}
	[ -z "$ATDIAL_WATCHDOG_PID" ] || {
		kill -TERM "$ATDIAL_WATCHDOG_PID" 2>/dev/null || :
		wait "$ATDIAL_WATCHDOG_PID" 2>/dev/null || :
		ATDIAL_WATCHDOG_PID=""
	}
}

atdial_scratch_init() {
	ATDIAL_OUT_FILE="$ATDIAL_SCRATCH_DIR/apn-atdial.$$.reply"
	ATDIAL_MARKER_FILE="$ATDIAL_SCRATCH_DIR/apn-atdial.$$.timeout"
}

atdial_scratch_clean() {
	rm -f "$ATDIAL_OUT_FILE" "$ATDIAL_MARKER_FILE" 2>/dev/null || :
}

# ---- the shared AT port lock ----
#
# Byte-compatible with apn-autoconfig-modem and apn-autoconfig-qmi: one file per
# tty containing the owner pid, with a guarded reclaim for a dead owner. The
# 0.10.0-era directory shape is still recognised, because an upgrade can leave
# one behind and a live process from the older package may legitimately hold it.

atdial_lock_owner_pid() {
	if [ -d "$1" ]; then
		atdial_owner="$(sed -n '1p' "$1/pid" 2>/dev/null || :)"
	else
		atdial_owner="$(sed -n '1p' "$1" 2>/dev/null || :)"
	fi
	case "$atdial_owner" in ''|*[!0-9]*|0) return 1 ;; esac
	printf '%s\n' "$atdial_owner"
}

# 0 acquired, 1 unusable path, 2 already present
atdial_lock_try() {
	atdial_path="$1"
	# `ln source directory` links *into* a directory instead of failing, so a
	# lock left behind in the old directory shape must be rejected here and
	# handled by the reclaim path rather than silently "acquired".
	[ -d "$atdial_path" ] && return 2
	atdial_tmp="${atdial_path}.tmp.$$"
	printf '%s\n' "$$" >"$atdial_tmp" 2>/dev/null || return 1
	if ln "$atdial_tmp" "$atdial_path" 2>/dev/null; then
		if [ -f "$atdial_path" ] && [ "$(sed -n '1p' "$atdial_path" 2>/dev/null)" = "$$" ]; then
			rm -f "$atdial_tmp"
			return 0
		fi
		rm -f "$atdial_path/${atdial_tmp##*/}" 2>/dev/null || :
		rm -f "$atdial_tmp"
		return 2
	fi
	rm -f "$atdial_tmp"
	return 2
}

atdial_lock_reclaim_if_stale() {
	atdial_reclaim_path="$1"
	atdial_guard="${atdial_reclaim_path}.reclaim"
	atdial_guard_owner="$(atdial_lock_owner_pid "$atdial_guard" 2>/dev/null || :)"
	if [ -n "$atdial_guard_owner" ] && ! atdial_process_alive "$atdial_guard_owner"; then
		rm -f "$atdial_guard" 2>/dev/null || :
	fi
	atdial_lock_try "$atdial_guard" || return 1
	atdial_reclaim_result=1
	atdial_reclaim_owner="$(atdial_lock_owner_pid "$atdial_reclaim_path" 2>/dev/null || :)"
	if [ -n "$atdial_reclaim_owner" ] && atdial_process_alive "$atdial_reclaim_owner"; then
		atdial_reclaim_result=1
	elif [ -d "$atdial_reclaim_path" ]; then
		rm -f "$atdial_reclaim_path/pid" 2>/dev/null || :
		rmdir "$atdial_reclaim_path" 2>/dev/null && atdial_reclaim_result=0
	else
		rm -f "$atdial_reclaim_path" 2>/dev/null && atdial_reclaim_result=0
	fi
	rm -f "$atdial_guard" 2>/dev/null || :
	return "$atdial_reclaim_result"
}

# 0 acquired, 1 unusable path, 3 held by a live owner
atdial_lock_try_or_reclaim() {
	atdial_attempt_path="$1"
	atdial_lock_try "$atdial_attempt_path"
	atdial_attempt_status=$?
	[ "$atdial_attempt_status" -eq 0 ] && return 0
	[ "$atdial_attempt_status" -eq 1 ] && return 1
	atdial_attempt_owner="$(atdial_lock_owner_pid "$atdial_attempt_path" 2>/dev/null || :)"
	if [ -n "$atdial_attempt_owner" ] && atdial_process_alive "$atdial_attempt_owner"; then
		return 3
	fi
	atdial_lock_reclaim_if_stale "$atdial_attempt_path" || return 3
	atdial_lock_try "$atdial_attempt_path"
	atdial_attempt_status=$?
	[ "$atdial_attempt_status" -eq 0 ] && return 0
	[ "$atdial_attempt_status" -eq 1 ] && return 1
	return 3
}

# Mandatory. A tty is effectively exclusive, and the address this handler
# publishes is read from a reply — so a caller that waits, fails and proceeds
# anyway configures the interface with another component's answer, which is up,
# wrong, and silent about it. Failing to acquire is a refusal.
atdial_lock_acquire() {
	atdial_lock_device="${1#/dev/}"
	atdial_valid_device_name "$atdial_lock_device" || return 1
	ATDIAL_LOCK_PATH="${ATDIAL_LOCK_ROOT}.${atdial_lock_device}"
	mkdir -p "$(dirname "$ATDIAL_LOCK_ROOT")" 2>/dev/null || return 1
	atdial_waited=0
	while :; do
		atdial_lock_try_or_reclaim "$ATDIAL_LOCK_PATH"
		atdial_lock_status=$?
		if [ "$atdial_lock_status" -eq 0 ]; then
			ATDIAL_LOCK_HELD=1
			return 0
		fi
		[ "$atdial_lock_status" -eq 3 ] || { ATDIAL_LOCK_PATH=""; return 1; }
		[ "$atdial_waited" -lt "$ATDIAL_LOCK_WAIT" ] || { ATDIAL_LOCK_PATH=""; return 1; }
		"$ATDIAL_SLEEP" 1
		atdial_waited=$((atdial_waited + 1))
	done
}

atdial_lock_release() {
	[ "$ATDIAL_LOCK_HELD" -eq 1 ] || return 0
	rm -f "$ATDIAL_LOCK_PATH" 2>/dev/null || :
	ATDIAL_LOCK_HELD=0
	ATDIAL_LOCK_PATH=""
}

# ---- the AT transport ----

# Strips CR, the echoed command and the final result code. Echo is a per-port
# property, not a per-modem one: one modem can present an echoing port and a
# silent port at the same moment, so it cannot be decided once for the device.
atdial_clean_reply() {
	awk -v sent="$1" '
		{
			gsub(/\r/, "")
			sub(/^[ \t]+/, "")
			sub(/[ \t]+$/, "")
			if ($0 == "" || $0 == sent || $0 == "OK" || $0 == "ERROR") next
			lines[n++] = $0
		}
		END { for (i = 0; i < n; i++) print lines[i] }
	'
}

# 0 with ATDIAL_REPLY set, 124 on timeout, otherwise the command's own status.
# The command is always a literal composed by the handler, never anything read
# from UCI, the environment, the GUI or another caller.
atdial_at() {
	atdial_device="$1"
	atdial_command="$2"
	ATDIAL_REPLY=""
	command -v "$ATDIAL_SMS_TOOL" >/dev/null 2>&1 || return 3
	atdial_at_status=0
	atdial_run_bounded "$ATDIAL_AT_TIMEOUT" \
		"$ATDIAL_SMS_TOOL" -d "$atdial_device" at "$atdial_command" || atdial_at_status=$?
	if [ "$ATDIAL_TIMED_OUT" -eq 1 ]; then
		rm -f "$ATDIAL_OUT_FILE" 2>/dev/null || :
		return 124
	fi
	ATDIAL_REPLY="$(atdial_clean_reply "$atdial_command" <"$ATDIAL_OUT_FILE" 2>/dev/null || :)"
	rm -f "$ATDIAL_OUT_FILE" 2>/dev/null || :
	return "$atdial_at_status"
}

# ---- sysfs ----

atdial_usb_dir() {
	printf '%s/bus/usb/devices/%s\n' "$ATDIAL_SYSFS_ROOT" "$1"
}

atdial_usb_attr() {
	atdial_attr_file="$(atdial_usb_dir "$1")/$2"
	[ -r "$atdial_attr_file" ] || return 1
	sed -n '1p' "$atdial_attr_file" 2>/dev/null
}

atdial_usb_present() {
	atdial_valid_usb_path "$1" || return 1
	[ -e "$(atdial_usb_dir "$1")/idVendor" ]
}

# The network device belonging to this USB device whose interface number is
# numerically lowest.
#
# Glob order is not interface order: ASCII sorts "1.10" before "1.6", so a
# device exposing three NCM interfaces hands the wrong one to a lexical
# comparison. That is not cosmetic on an Intel part, where the data-channel
# binding names the *first* NCM interface explicitly — bind the context to one
# interface and publish another, and the link is up and carries nothing.
atdial_netdev_for_usb_path() {
	atdial_valid_usb_path "$1" || return 1
	atdial_best=""
	atdial_best_num=""
	for atdial_net in "$(atdial_usb_dir "$1")":*/net/*; do
		[ -e "$atdial_net" ] || continue
		atdial_iface="${atdial_net%/net/*}"
		atdial_iface="${atdial_iface##*:}"
		atdial_iface="${atdial_iface#*.}"
		case "$atdial_iface" in ''|*[!0-9]*) continue ;; esac
		if [ -z "$atdial_best_num" ] || [ "$atdial_iface" -lt "$atdial_best_num" ]; then
			atdial_best_num="$atdial_iface"
			atdial_best="${atdial_net##*/}"
		fi
	done
	[ -n "$atdial_best" ] || return 1
	printf '%s\n' "$atdial_best"
}

atdial_netdev_exists() {
	case "$1" in ''|*/*) return 1 ;; esac
	[ -d "$ATDIAL_SYSFS_ROOT/class/net/$1" ]
}

# Changes on every enumeration, which is what makes it a usable "has this modem
# rebooted since we last spoke to it" marker.
atdial_usb_devnum() {
	atdial_usb_attr "$1" devnum 2>/dev/null || return 1
}

# ---- transport quirks ----

# One value from the transport quirk table, or nothing.
#
# An absent entry means "not tested here", never "probably like the others" —
# the same rule the capability table in apn-autoconfig-modem applies, for the
# same reason. A device nobody has driven gets the standard path and no
# vendor-specific commands, which fails visibly rather than misbehaving.
#
# The most specific match wins so an entry can be narrowed later: exact model,
# then exact product, then vendor alone.
atdial_quirk() {
	[ -r "$ATDIAL_QUIRKS" ] || return 1
	atdial_quirk_vendor="$1"
	atdial_quirk_product="$2"
	atdial_quirk_model="$3"
	atdial_quirk_key="$4"
	[ -n "$atdial_quirk_vendor" ] && [ -n "$atdial_quirk_key" ] || return 1
	atdial_quirk_result="$(awk -F '\t' \
		-v vendor="$atdial_quirk_vendor" -v product="$atdial_quirk_product" \
		-v model="$atdial_quirk_model" -v key="$atdial_quirk_key" '
		/^[ \t]*#/ { next }
		NF < 5 { next }
		$1 != vendor || $4 != key { next }
		{ sub(/[ \t]*#.*$/, "", $5) }
		$2 == product && $3 == model { exact = $5; next }
		$2 == product && $3 == "*" { by_product = $5; next }
		$2 == "*" && $3 == "*" { by_vendor = $5 }
		END {
			if (exact != "") { print exact; exit 0 }
			if (by_product != "") { print by_product; exit 0 }
			if (by_vendor != "") { print by_vendor; exit 0 }
			exit 1
		}
	' "$ATDIAL_QUIRKS" 2>/dev/null)" || return 1
	[ -n "$atdial_quirk_result" ] || return 1
	case "$atdial_quirk_result" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
	printf '%s\n' "$atdial_quirk_result"
}
