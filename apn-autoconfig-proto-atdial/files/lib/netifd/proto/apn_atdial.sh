#!/bin/sh

# netifd protocol handler: apn_atdial
#
# Data connection for AT-dialed modems that expose no control channel at all.
# QMI, MBIM and ModemManager all speak to a cdc-wdm character device; a modem in
# an RNDIS, ECM or NCM composition has none. Its data path is an ordinary usbnet
# interface, so the host has to define and activate the PDP context itself over
# an AT port and then put the modem-reported address on the interface. The modem
# serves no DHCP, so nothing else will do it.
#
# The commands are plain 3GPP and identical across vendors. What differs, and
# what most of this file is about, is everything around them: which node accepts
# them, who is allowed to talk to it, and what must be true before dialing is
# meaningful at all. See docs/atdial-contract-v1.md.
#
# Ports are never probed here. apn-autoconfig-modem resolves them by observed
# role, caches negative verdicts and refuses under ModemManager; a second
# resolver racing it for the same tty is the failure that contract exists to
# prevent.

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

. "${APN_ATDIAL_LIB:-/usr/share/apn-autoconfig-proto-atdial/atdial.sh}"

ATDIAL_ACTIVATED=0
ATDIAL_INTERFACE=""
ATDIAL_DATA_CHANNEL=""
ATDIAL_DNS_SOURCE=""
ATDIAL_LINK_ARP=""

atdial_log() {
	echo "apn_atdial[$$] $*"
}

# One field of the modem package's read-only record. status-json opens no
# control channel, so this is safe to call while this handler holds the AT port
# lock — which asking at-port again would not be, because resolving a port that
# is not already cached needs that same lock and would deadlock against us.
atdial_modem_field() {
	local id="$1" field="$2" record
	[ -n "$id" ] || return 1
	[ -x "$ATDIAL_MODEM_BIN" ] || return 1
	command -v jsonfilter >/dev/null 2>&1 || return 1
	record="$("$ATDIAL_MODEM_BIN" status-json --modem "$id" 2>/dev/null)" || return 1
	printf '%s' "$record" | jsonfilter -e "@.$field" 2>/dev/null
}

# Arms before the first command that changes anything. netifd can be stopped at
# any moment, and an interrupted bring-up must not leave a child holding the
# serial port or the shared lock: the next attempt would then fail on a lock
# whose owner is gone, and every other component of the suite would wait on it.
atdial_interrupted() {
	trap '' HUP INT TERM
	atdial_reap
	# One bounded attempt to put back what we changed. If the port has gone
	# with the modem, this times out and we still release the lock — leaving it
	# held would be the worse failure of the two.
	[ "$ATDIAL_ACTIVATED" -eq 1 ] && [ -n "$ATDIAL_DIAL_PORT" ] && \
		atdial_at "$ATDIAL_DIAL_PORT" 'AT+CGACT=0,1' >/dev/null 2>&1
	atdial_lock_release
	atdial_scratch_clean
	exit 1
}

# Every exit from setup goes through here, so the lock and the scratch files
# have exactly one release path.
atdial_finish() {
	trap - HUP INT TERM
	atdial_reap
	atdial_lock_release
	atdial_scratch_clean
}

atdial_fail() {
	local iface="$1" code="$2" block="$3"
	shift 3
	[ "$#" -eq 0 ] || atdial_log "$*"
	atdial_finish
	proto_notify_error "$iface" "$code"
	[ "$block" = 1 ] && proto_block_restart "$iface"
	return 1
}

# 3GPP TS 27.007 accepts IP, IPV6 and IPV4V6 and nothing else. IPV4 is not a
# valid value: a modem that answers ERROR to it leaves the previous context in
# place, so the previous SIM's APN silently survives and every dial uses it.
atdial_normalise_pdptype() {
	case "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" in
		IPV4|IP) printf '%s\n' IP ;;
		IPV6) printf '%s\n' IPV6 ;;
		IPV4V6|IPV46) printf '%s\n' IPV4V6 ;;
		'') printf '%s\n' IPV4V6 ;;
		*) printf '%s\n' IPV4V6 ;;
	esac
}

# The <stat> of the first registration source that answers. CEREG and CGREG are
# preferred over CREG, and not as a matter of taste: a device attached over LTE
# or 5G with no CS domain answers CREG with 6, "registered, SMS only", and
# reading CREG first would call a fully registered modem unregistered.
atdial_registration_stat() {
	local port="$1" cmd stat
	for cmd in 'AT+CEREG?' 'AT+CGREG?' 'AT+CREG?'; do
		atdial_at "$port" "$cmd" || continue
		stat="$(printf '%s\n' "$ATDIAL_REPLY" | awk -F, '
			/^\+C[EG]?REG:/ { gsub(/[^0-9]/, "", $2); print $2; exit }
		')"
		case "$stat" in ''|*[!0-9]*) continue ;; esac
		printf '%s\n' "$stat"
		return 0
	done
	return 1
}

# 0 for auto, 1 for manual, 2 for deregistered.
atdial_cops_mode() {
	atdial_at "$1" 'AT+COPS?' || return 1
	printf '%s\n' "$ATDIAL_REPLY" | sed -n 's/^+COPS: *\([0-9]\).*/\1/p' | sed -n '1p'
}

atdial_current_plmn() {
	atdial_at "$1" 'AT+COPS?' || return 1
	printf '%s\n' "$ATDIAL_REPLY" | sed -n 's/^+COPS:.*,"\([0-9]\{5,6\}\)".*/\1/p' | sed -n '1p'
}

atdial_context_address() {
	atdial_at "$1" 'AT+CGPADDR=1' || return 1
	printf '%s\n' "$ATDIAL_REPLY" |
		sed -n 's/.*+CGPADDR: *1,"\{0,1\}\([0-9.]\{7,\}\)"\{0,1\}.*/\1/p' | sed -n '1p'
}

# PDP authentication. The command is standard 3GPP; a modem without it answers
# ERROR and a profile with no credentials is unaffected. `none` is written
# explicitly rather than skipped, so a previous SIM's credentials cannot survive
# into a profile that has none.
#
# Nothing here reaches a log. The values are a subscriber's credentials.
atdial_set_auth() {
	local port="$1" mode="$2" user="$3" secret="$4"
	case "$mode" in
		pap)  atdial_at "$port" "AT+CGAUTH=1,1,\"$user\",\"$secret\"" >/dev/null 2>&1 ;;
		chap) atdial_at "$port" "AT+CGAUTH=1,2,\"$user\",\"$secret\"" >/dev/null 2>&1 ;;
		none|'') atdial_at "$port" 'AT+CGAUTH=1,0' >/dev/null 2>&1 ;;
		# Never silently. AT+CGAUTH takes one protocol, so `pap-or-chap` has to
		# be expanded into attempts by the caller — and falling through to
		# "no authentication" here would hand the network a profile that has
		# credentials without using them: an address is assigned and no traffic
		# passes, which looks like a working connection from every angle except
		# the only one that matters.
		*) return 1 ;;
	esac
	return 0
}

# The authentication protocols to try, in order.
#
# AT+CGAUTH accepts one protocol per context, so a normalized `pap-or-chap`
# profile becomes bounded attempts — CHAP first, as the MBIM backend already
# does for the same reason. The protocol that worked is remembered, so the next
# bring-up starts with it instead of rediscovering it every time.
atdial_auth_attempts() {
	local mode="$1" interface="$2" remembered=""
	case "$mode" in
		pap-or-chap)
			remembered="$(cat "$ATDIAL_SCRATCH_DIR/apn-atdial-authmode.$interface" 2>/dev/null || :)"
			case "$remembered" in
				pap) printf 'pap\nchap\n' ;;
				chap) printf 'chap\npap\n' ;;
				*) printf 'chap\npap\n' ;;
			esac
		;;
		''|none) printf 'none\n' ;;
		*) printf '%s\n' "$mode" ;;
	esac
}

# Define the context, authenticate it, activate it and return the address.
#
# The release before activation is unconditional: a bare re-activation hangs
# when the context is wedged half-active, and on a cold context the release is a
# harmless no-op. Detecting the wedged state reliably is not possible, so the
# cheap unconditional fix wins over the clever conditional one.
atdial_activate() {
	local port="$1" pdptype="$2" apn="$3" auth="$4" user="$5" secret="$6"
	local try address=""

	# The vendor DNS report has to be enabled before the context comes up, or
	# the query afterwards answers empty.
	[ "$ATDIAL_DNS_SOURCE" = xdns ] && atdial_at "$port" 'AT+XDNS=1,1' >/dev/null 2>&1
	atdial_at "$port" "AT+CGDCONT=1,\"$pdptype\",\"$apn\"" >/dev/null 2>&1
	atdial_set_auth "$port" "$auth" "$user" "$secret"
	ATDIAL_ACTIVATED=1
	atdial_at "$port" 'AT+CGACT=0,1' >/dev/null 2>&1
	"$ATDIAL_SLEEP" 2
	for try in 1 2 3 4 5 6; do
		atdial_at "$port" 'AT+CGACT=1,1' >/dev/null 2>&1
		"$ATDIAL_SLEEP" 2
		address="$(atdial_context_address "$port" || :)"
		[ -n "$address" ] && [ "$address" != 0.0.0.0 ] && {
			# An address is not yet a data path on these devices: the first NCM
			# channel has to be bound to the context and data started, or the
			# interface comes up carrying nothing at all.
			if [ "$ATDIAL_DATA_CHANNEL" = xmm ]; then
				atdial_at "$port" \
					'AT+XDATACHANNEL=1,1,"/USBCDC/0","/USBHS/NCM/0",2,1' >/dev/null 2>&1
				atdial_at "$port" 'AT+CGDATA="M-RAW_IP",1' >/dev/null 2>&1
			fi
			printf '%s\n' "$address"
			return 0
		}
	done
	return 1
}

# The firewall zone of the parent interface, which the dynamic IPv6 child needs:
# without it the RA and DHCPv6 replies meet the default input policy and the
# operator's prefix never arrives. fw3 answers directly; fw4 has no such command,
# so the zone is found by looking through the configured network lists.
atdial_firewall_zone() {
	local zone index=0 name entry
	zone="$(fw3 -q network "$1" 2>/dev/null || :)"
	[ -n "$zone" ] && { printf '%s\n' "$zone"; return 0; }
	while name="$(uci -q get "firewall.@zone[$index].name" 2>/dev/null)"; [ -n "$name" ]; do
		for entry in $(uci -q get "firewall.@zone[$index].network" 2>/dev/null); do
			[ "$entry" = "$1" ] && { printf '%s\n' "$name"; return 0; }
		done
		index=$((index + 1))
	done
	return 1
}

proto_apn_atdial_init_config() {
	no_device=1
	available=1
	proto_config_add_string "usbpath"
	proto_config_add_string "modem_id"
	proto_config_add_string "device"
	proto_config_add_string "atport"
	proto_config_add_string "apn"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_string "auth"
	proto_config_add_string "pdptype"
	proto_config_add_int "metric"
	proto_config_add_boolean "allow_roaming"
	proto_config_add_defaults
}

proto_apn_atdial_setup() {
	local interface="$1"
	local usbpath modem_id device atport apn username password auth pdptype metric allow_roaming
	local netdev dial stat waited kicked address gw dns1 dns2 rdp mask live_pdp zone6 value

	json_get_vars usbpath modem_id device atport apn username password auth \
		pdptype metric allow_roaming

	ATDIAL_INTERFACE="$interface"
	ATDIAL_ACTIVATED=0
	ATDIAL_DIAL_PORT=""
	atdial_scratch_init

	pdptype="$(atdial_normalise_pdptype "$pdptype")"

	# Every value below is interpolated into an AT command string. A quote would
	# close the argument early and a carriage return would end the command line,
	# so either lets a profile field compose a second command. The administrator
	# already has root, so this is not a privilege boundary — it is the
	# difference between a clear refusal and a malformed command whose failure
	# points nowhere near its cause.
	for value in "$apn" "$username" "$password"; do
		atdial_safe_value "$value" || {
			atdial_fail "$interface" NO_IP_ADDRESS 1 \
				'a profile field contains a character that cannot be sent in an AT command'
			return 1
		}
	done

	# usbpath records where the modem was when the section was created, not what
	# it is. A modem moved to another socket leaves it pointing at nothing, so
	# the binding is re-resolved from the stable identity rather than trusted.
	if [ -n "$usbpath" ] && ! atdial_usb_present "$usbpath"; then
		if [ -n "$modem_id" ]; then
			value="$(atdial_modem_field "$modem_id" usb_path || :)"
			value="${value##*/}"
			if [ -n "$value" ] && atdial_usb_present "$value"; then
				atdial_log "usbpath $usbpath is no longer on the bus; using $value for $modem_id"
				usbpath="$value"
			fi
		fi
	fi

	netdev=""
	if [ -n "$usbpath" ]; then
		netdev="$(atdial_netdev_for_usb_path "$usbpath" 2>/dev/null || :)"
		# No network device usually means no bound driver rather than no modem.
		# The measured hardware presents an RNDIS interface pair with nothing
		# bound to it, so a handler that waits for a netdev waits forever.
		# Loading a usbnet module makes the kernel scan devices already present,
		# and modprobe on a loaded module is a no-op.
		if [ -z "$netdev" ]; then
			"$ATDIAL_MODPROBE" rndis_host 2>/dev/null || :
			"$ATDIAL_MODPROBE" cdc_ether 2>/dev/null || :
			"$ATDIAL_MODPROBE" cdc_ncm 2>/dev/null || :
			waited=0
			while [ "$waited" -lt 5 ]; do
				netdev="$(atdial_netdev_for_usb_path "$usbpath" 2>/dev/null || :)"
				[ -n "$netdev" ] && break
				"$ATDIAL_SLEEP" 1
				waited=$((waited + 1))
			done
		fi
	fi
	[ -n "$netdev" ] || netdev="$device"
	if [ -z "$netdev" ]; then
		atdial_fail "$interface" NO_NETDEV 0 \
			"no network device for usbpath \"$usbpath\" and no configured device"
		return 1
	fi
	# A name from the config is not evidence that it exists. Publishing an
	# update for a device that is absent makes netifd fail the interface and
	# immediately bring it up again, forever, explaining nothing.
	if ! atdial_netdev_exists "$netdev"; then
		atdial_fail "$interface" NETDEV_MISSING 1 \
			"configured device \"$netdev\" does not exist"
		return 1
	fi

	# The modem package owns port resolution, the negative cache and the refusal
	# under ModemManager. Exit 4 there is an ownership refusal, which is a
	# different thing from having found no port.
	dial="$atport"
	if [ -z "$dial" ] && [ -n "$modem_id" ] && [ -x "$ATDIAL_MODEM_BIN" ]; then
		# Once, with its status captured. `if ! cmd` would have inverted the
		# status before it could be read, and exit 4 here is an ownership
		# refusal rather than a failure to find a port — a different outcome
		# that has to reach the user as a different error.
		local port_status=0
		dial="$("$ATDIAL_MODEM_BIN" at-port --modem "$modem_id" 2>/dev/null)" || port_status=$?
		if [ "$port_status" -eq 4 ]; then
			atdial_fail "$interface" OWNER_CONFLICT 1 \
				"another control owner holds $modem_id; not opening its AT port"
			return 1
		fi
	fi
	if [ -z "$dial" ]; then
		atdial_fail "$interface" NO_AT_PORT 0 \
			"no AT control port for usbpath \"$usbpath\""
		return 1
	fi
	ATDIAL_DIAL_PORT="$dial"

	# Mandatory. The address published below is read from a reply, so a caller
	# that waits, fails and reads anyway configures the interface with another
	# component's answer.
	if ! atdial_lock_acquire "$dial"; then
		atdial_fail "$interface" AT_PORT_BUSY 0 \
			"AT port $dial is held by another component"
		return 1
	fi
	trap 'atdial_interrupted' HUP INT TERM

	# Ownership is re-read now that the port is held. Validation before the lock
	# has a time-of-check/time-of-use gap, and this modem class closes it the
	# wrong way routinely: ModemManager publishes a freshly attached modem only
	# after probing every port, so unowned-then-owned is the ordinary sequence.
	if [ -n "$modem_id" ]; then
		value="$(atdial_modem_field "$modem_id" owner_state || :)"
		case "$value" in
			modemmanager|conflicting)
				atdial_fail "$interface" OWNER_CONFLICT 1 \
					"$modem_id became $value while its port was being taken"
				return 1
			;;
		esac
	fi

	# Transport quirks, resolved now that the port is held. The model comes from
	# the modem rather than from the identity cache, because the cache is only
	# populated once an identity read has happened and a first-ever dial cannot
	# depend on that having occurred. One command is nothing beside a dial.
	ATDIAL_DATA_CHANNEL=""
	ATDIAL_DNS_SOURCE=""
	ATDIAL_LINK_ARP=""
	if [ -n "$usbpath" ]; then
		local quirk_vendor quirk_product quirk_model=""
		quirk_vendor="$(atdial_usb_attr "$usbpath" idVendor 2>/dev/null || :)"
		quirk_product="$(atdial_usb_attr "$usbpath" idProduct 2>/dev/null || :)"
		atdial_at "$dial" 'AT+CGMM' && quirk_model="$(printf '%s\n' "$ATDIAL_REPLY" | sed -n '1p')"
		ATDIAL_DATA_CHANNEL="$(atdial_quirk "$quirk_vendor" "$quirk_product" "$quirk_model" data_channel || :)"
		ATDIAL_DNS_SOURCE="$(atdial_quirk "$quirk_vendor" "$quirk_product" "$quirk_model" dns_source || :)"
		ATDIAL_LINK_ARP="$(atdial_quirk "$quirk_vendor" "$quirk_product" "$quirk_model" link_arp || :)"
		[ -n "$ATDIAL_DATA_CHANNEL$ATDIAL_DNS_SOURCE$ATDIAL_LINK_ARP" ] && \
			atdial_log "transport quirks for ${quirk_vendor}:${quirk_product} (${quirk_model:-unknown model}): data_channel=${ATDIAL_DATA_CHANNEL:-none} dns_source=${ATDIAL_DNS_SOURCE:-none} link_arp=${ATDIAL_LINK_ARP:-none}"
	fi

	# Registration is read once and decides roaming, permanent refusal and "no
	# network yet" together. A modem that has just powered on honestly takes
	# tens of seconds to find a network, so the first answer is not the verdict;
	# this wait doubles as the interval between netifd retries.
	waited=0
	kicked=0
	while :; do
		stat="$(atdial_registration_stat "$dial" || :)"
		case "$stat" in 1|5|6|7|9|10) break ;; esac
		# A deregistered modem does not come back on its own: at mode 2 it does
		# not look for a network at all. The trigger is the +COPS mode, not a
		# stat code, because the stat a deregistered modem reports varies by
		# device while mode 2 does not. Mode 1 is a manual operator choice by
		# the user and is never overridden.
		if [ "$kicked" = 0 ] && [ "$(atdial_cops_mode "$dial" || :)" = 2 ]; then
			kicked=1
			atdial_log 'modem is deregistered (+COPS: 2) - re-enabling automatic selection'
			atdial_at "$dial" 'AT+COPS=0' >/dev/null 2>&1
		fi
		[ "$waited" -ge 60 ] && break
		"$ATDIAL_SLEEP" 5
		waited=$((waited + 5))
	done

	case "$stat" in
		5|7|10)
			# There is no roaming switch inside these modems, so the policy is
			# enforced here, as mbim.sh does: a roaming registration does not
			# get a connection. That is what the option means to a user — the
			# bill follows bytes carried, not the fact of registering.
			if [ "$allow_roaming" != 1 ]; then
				atdial_fail "$interface" ROAMING_NOT_ALLOWED 1 \
					"registered while roaming (stat $stat) and roaming is not allowed"
				return 1
			fi
		;;
		1|6|9) : ;;
		3)
			# Not "has not found one yet": this is what an unregistered SIM, an
			# unpaid account or a blocked IMEI answers. Retrying cannot help.
			atdial_fail "$interface" REGISTRATION_DENIED 1 \
				'the network refused registration (stat 3)'
			return 1
		;;
		*)
			# Restarts are deliberately not blocked: signal can return on its
			# own, and the interface must come up without a human when it does.
			atdial_fail "$interface" NOT_REGISTERED 0 \
				"no network registration (stat \"${stat:-no reply}\") after ${waited}s"
			return 1
		;;
	esac

	address=""
	if atdial_reuse_is_safe "$dial" "$apn" "$pdptype" "$auth" "$username" "$usbpath" "$interface"; then
		address="$(atdial_context_address "$dial" || :)"
		[ "$address" = 0.0.0.0 ] && address=""
	fi

	if [ -z "$address" ]; then
		local alternate=IPV4V6 try_pdp try_auth effective_auth=""
		[ "$pdptype" = IPV4V6 ] && alternate=IP
		# Some SIMs bring up the default bearer only under one PDP type, and a
		# `pap-or-chap` profile has to be resolved to one protocol. Both are
		# failure paths only: a profile that works on the first attempt issues
		# exactly the commands it always did.
		for try_pdp in "$pdptype" "$alternate"; do
			[ "$try_pdp" = "$alternate" ] && [ -z "$address" ] && \
				atdial_log "no address with $pdptype, retrying with $alternate"
			for try_auth in $(atdial_auth_attempts "$auth" "$interface"); do
				address="$(atdial_activate "$dial" "$try_pdp" "$apn" "$try_auth" "$username" "$password" || :)"
				[ -n "$address" ] && { effective_auth="$try_auth"; break; }
			done
			[ -n "$address" ] && break
		done
		# Remember which protocol the network accepted, not which was requested.
		case "$auth" in
			pap-or-chap)
				[ -z "$effective_auth" ] || printf '%s' "$effective_auth" \
					>"$ATDIAL_SCRATCH_DIR/apn-atdial-authmode.$interface" 2>/dev/null || :
			;;
		esac
	fi
	if [ -z "$address" ]; then
		atdial_fail "$interface" NO_IP_ADDRESS 1 'the context did not activate under either PDP type'
		return 1
	fi

	# +CGCONTRDP: <cid>,<bearer>,<apn>,<addr and mask>,<gw>,<dns1>,<dns2>,...
	# so after splitting on commas the gateway is field 5 and DNS are 6 and 7.
	# On a point-to-point cellular link the gateway is usually empty, and the
	# default route is then on-link.
	rdp=""
	atdial_at "$dial" 'AT+CGCONTRDP=1' && \
		rdp="$(printf '%s\n' "$ATDIAL_REPLY" | grep '+CGCONTRDP:' | sed -n '1p')"
	gw="$(printf '%s' "$rdp" | awk -F, '{ gsub(/"/, "", $5); print $5 }')"
	dns1="$(printf '%s' "$rdp" | awk -F, '{ gsub(/"/, "", $6); print $6 }')"
	dns2="$(printf '%s' "$rdp" | awk -F, '{ gsub(/"/, "", $7); print $7 }')"

	# Field 4 carries the address and its netmask as eight octets, so the mask
	# the network actually assigned is available rather than assumed. Cellular
	# links are frequently not /24, and guessing one produces an on-link subnet
	# that does not exist. A malformed or absent field falls back to the /24 that
	# the explicit default route below has always made work.
	mask="$(printf '%s' "$rdp" | awk -F, '{ gsub(/"/, "", $4); print $4 }' |
		awk -F. 'NF == 8 { printf "%s.%s.%s.%s", $5, $6, $7, $8 }')"
	case "$mask" in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*) : ;;
		*) mask=255.255.255.0 ;;
	esac

	# The live context's type, not the configured one: the fallback above may
	# have changed it, and that is what decides whether IPv6 exists.
	live_pdp=""
	atdial_at "$dial" 'AT+CGDCONT?' && \
		live_pdp="$(printf '%s\n' "$ATDIAL_REPLY" |
			sed -n 's/^+CGDCONT: *1,"\([^"]*\)".*/\1/p' | sed -n '1p')"

	# Record the network this dial succeeded on, so a later bring-up can tell an
	# operator change from an ordinary reconnect.
	value="$(atdial_current_plmn "$dial" || :)"
	[ -n "$value" ] && printf '%s' "$value" >"$ATDIAL_SCRATCH_DIR/apn-atdial-plmn.$interface" 2>/dev/null
	value="$(atdial_usb_devnum "$usbpath" 2>/dev/null || :)"
	[ -n "$value" ] && printf '%s' "$value" >"$ATDIAL_SCRATCH_DIR/apn-atdial-auth.$interface" 2>/dev/null

	# On these devices AT+CGCONTRDP answers nothing, so DNS comes from the
	# vendor query instead. It is read after activation because that is when it
	# has an answer.
	if [ "$ATDIAL_DNS_SOURCE" = xdns ]; then
		local xdns=""
		atdial_at "$dial" 'AT+XDNS?' && \
			xdns="$(printf '%s\n' "$ATDIAL_REPLY" | grep '^+XDNS: 1,' | sed -n '1p')"
		if [ -n "$xdns" ]; then
			dns1="$(printf '%s' "$xdns" | awk -F'"' '{ print $2 }')"
			dns2="$(printf '%s' "$xdns" | awk -F'"' '{ print $4 }')"
		fi
	fi

	ip link set "$netdev" up 2>/dev/null || :
	if [ "$ATDIAL_LINK_ARP" = off ]; then
		# The NCM channel does not answer ARP. Without disabling it the address
		# is configured and every packet dies in neighbour resolution — an
		# interface that is up and carries nothing. There is no gateway either,
		# so the default route is on-link.
		ip link set "$netdev" arp off 2>/dev/null || :
		gw=""
	fi

	# The AT port is no longer needed. Everything below is addresses and routes,
	# so the lock goes back to identity and status readers as early as possible
	# rather than at the end of the function.
	atdial_finish

	proto_init_update "$netdev" 1
	proto_add_ipv4_address "$address" "$mask"
	case "$gw" in
		''|0.0.0.0) proto_add_ipv4_route "0.0.0.0" "0" "" "" "$metric" ;;
		*) proto_add_ipv4_route "0.0.0.0" "0" "$gw" "" "$metric" ;;
	esac
	[ -n "$dns1" ] && [ "$dns1" != 0.0.0.0 ] && proto_add_dns_server "$dns1"
	[ -n "$dns2" ] && [ "$dns2" != 0.0.0.0 ] && proto_add_dns_server "$dns2"
	proto_send_update "$interface"

	# A routable IPv6 prefix does not arrive through CGPADDR — that carries an
	# interface identifier. It comes by RA or DHCPv6 on the usbnet interface,
	# with the modem acting as the router, so IPv6 is a dynamic child rather
	# than a static address. Only when the live context is actually v6-capable:
	# after a fallback it may be plain IPv4.
	case "$live_pdp" in
		*[vV]6*)
			zone6="$(atdial_firewall_zone "$interface" 2>/dev/null || :)"
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcpv6"
			json_add_string extendprefix 1
			proto_add_dynamic_defaults
			[ -n "$zone6" ] && json_add_string zone "$zone6"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
			atdial_log "IPv6 ($live_pdp): started dhcpv6 child ${interface}_6 in zone ${zone6:-none}"
		;;
	esac
}

# Reuse a live context only when every condition holds. Each of these exists
# because its absence produces an interface that is up and carries nothing,
# which is the worst failure this handler can produce: everything reports
# success and no traffic moves.
atdial_reuse_is_safe() {
	local port="$1" apn="$2" pdptype="$3" auth="$4" user="$5" usbpath="$6" interface="$7"
	local context live_apn live_pdp attached plmn previous devnum

	atdial_at "$port" 'AT+CGACT?' || return 1
	printf '%s\n' "$ATDIAL_REPLY" | grep -qE '^\+CGACT: *1,1' || return 1

	# A modem that just booted may have activated context 1 by itself, with the
	# APN it last held — often the previous SIM's. Reusing that means a newly
	# chosen APN never takes effect.
	atdial_at "$port" 'AT+CGDCONT?' || return 1
	context="$(printf '%s\n' "$ATDIAL_REPLY" | grep '^+CGDCONT: *1,' | sed -n '1p')"
	live_pdp="$(printf '%s' "$context" | sed -n 's/^+CGDCONT: *1,"\([^"]*\)".*/\1/p')"
	live_apn="$(printf '%s' "$context" | sed -n 's/^+CGDCONT: *1,"[^"]*","\([^"]*\)".*/\1/p')"
	[ -z "$apn" ] || [ "$live_apn" = "$apn" ] || {
		atdial_log 'the live context is on a different APN - dialing cold'
		return 1
	}
	# No modem upgrades a context in place, so an IPV4V6 request over a live IP
	# context would reuse an IPv4-only bearer and IPv6 would never appear.
	[ "$live_pdp" = "$pdptype" ] || {
		atdial_log "the live context is $live_pdp, not $pdptype - dialing cold"
		return 1
	}

	# An active context on a detached modem is a dead bearer: the address is
	# still reported and nothing traverses it. qmi.sh makes the same check
	# through its data-status query before declaring success.
	atdial_at "$port" 'AT+CGATT?' || return 1
	attached="$(printf '%s\n' "$ATDIAL_REPLY" | sed -n 's/^+CGATT: *\([0-9]\).*/\1/p' | sed -n '1p')"
	[ "$attached" = 1 ] || {
		atdial_log 'the context is active but the modem is not attached - dialing cold'
		return 1
	}

	# CGAUTH does not survive a modem reboot while CGDCONT does, so the context
	# can match perfectly and still be an unauthenticated bearer — an address
	# with no traffic, again. Re-enumeration is what a reboot looks like from
	# here, and devnum changes on every enumeration.
	case "$auth" in
		pap|chap|pap-or-chap)
			if [ -n "$user" ]; then
				devnum="$(atdial_usb_devnum "$usbpath" 2>/dev/null || :)"
				previous="$(cat "$ATDIAL_SCRATCH_DIR/apn-atdial-auth.$interface" 2>/dev/null || :)"
				[ -n "$previous" ] && [ "$devnum" = "$previous" ] || {
					atdial_log 'the modem re-enumerated since authentication was sent - dialing cold'
					return 1
				}
			fi
		;;
	esac

	# A changed operator means the previous session belongs to a network we are
	# no longer on. Tracking area changes are deliberately *not* used: they
	# change while driving across a city with the session perfectly alive, and
	# reconnecting on every one of them would be worse than the problem.
	plmn="$(atdial_current_plmn "$port" || :)"
	previous="$(cat "$ATDIAL_SCRATCH_DIR/apn-atdial-plmn.$interface" 2>/dev/null || :)"
	if [ -n "$previous" ] && [ -n "$plmn" ] && [ "$plmn" != "$previous" ]; then
		atdial_log "the network changed ($previous -> $plmn) - dialing cold"
		return 1
	fi
	return 0
}

proto_apn_atdial_teardown() {
	local interface="$1"
	local modem_id usbpath atport dial

	json_get_vars modem_id usbpath atport

	atdial_scratch_init
	dial="$atport"
	if [ -z "$dial" ] && [ -n "$modem_id" ] && [ -x "$ATDIAL_MODEM_BIN" ]; then
		dial="$("$ATDIAL_MODEM_BIN" at-port --modem "$modem_id" 2>/dev/null || :)"
	fi

	# The context is released rather than left up.
	#
	# Leaving it would make a reconfigure — a metric change, a reload —
	# reconnect instantly instead of re-dialing, and that is a real benefit
	# this handler gives up on purpose. netifd is the sole bearer owner here,
	# and a data session that outlives the interface owning it is exactly the
	# state the project's invariants forbid: nothing in the system reports a
	# bearer no interface claims, so it cannot be found again except by
	# dialing over it.
	if [ -n "$dial" ] && atdial_lock_acquire "$dial"; then
		atdial_at "$dial" 'AT+CGACT=0,1' >/dev/null 2>&1
		atdial_lock_release
	fi
	atdial_scratch_clean

	# Nothing is reported to netifd here. It has already moved the interface
	# into its teardown state by the time this runs, and proto_ext_update_link
	# answers PERMISSION_DENIED in that state — so the notification cannot
	# succeed and only produces a permission-denied line on every disconnect.
	# Error codes travel by another path and still arrive.
}

[ -n "$INCLUDE_ONLY" ] || add_protocol apn_atdial
