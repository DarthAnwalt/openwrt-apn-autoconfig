#!/bin/sh
set -eu

# Executes the package maintainer scripts instead of grepping their text.
#
# The hooks live inside the OpenWrt Makefiles, so each one is extracted and
# unescaped exactly as make would hand it to the packaging tool, then run.
#
# Two techniques keep this safe on a developer machine:
#
#  - the offline-install check runs a hook unmodified, with rm, rmdir, uci,
#    kill, logger and the init script replaced by recorders. If the
#    IPKG_INSTROOT guard were broken, the attempt is recorded rather than
#    performed, and the test fails on the recording.
#  - the live checks rewrite the absolute state paths to a sandbox. Only the
#    path prefixes change: the loops, PID checks and guards under test are the
#    shipped ones.

BASE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TESTROOT="$(CDPATH= cd -- /tmp && pwd -P)/apn-autoconfig-lifecycle-test.$$"
MOCKBIN="$TESTROOT/bin"
SANDBOX="$TESTROOT/root"
RECORD="$TESTROOT/recorded-calls"

cleanup() {
	rm -rf "$TESTROOT"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$MOCKBIN" "$SANDBOX"
: >"$RECORD"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

# Extracts one "define Package/<name>/<hook> ... endef" body and undoes make's
# doubling of the dollar sign, which is how the packaging tool receives it.
extract_hook() {
	makefile="$1"
	hook="$2"
	awk -v want="$hook" '
		$0 ~ ("^define " want "$") { inside = 1; next }
		inside && /^endef$/ { inside = 0; exit }
		inside { print }
	' "$makefile" | sed 's/\$\$/$/g'
}

for tool in rm rmdir uci kill logger; do
	cat >"$MOCKBIN/$tool" <<EOF
#!/bin/sh
printf '%s %s\n' "$tool" "\$*" >>"\$RECORD_FILE"
exit 0
EOF
	chmod 0755 "$MOCKBIN/$tool"
done

printf '%s\n' 'TEST an offline image-root install performs no live action'
for package_hook in \
	"$BASE/apn-autoconfig-modem/Makefile:Package/apn-autoconfig-modem/postinst" \
	"$BASE/apn-autoconfig-modem/Makefile:Package/apn-autoconfig-modem/prerm" \
	"$BASE/apn-autoconfig-modem/Makefile:Package/apn-autoconfig-modem/postrm" \
	"$BASE/Makefile:Package/apn-autoconfig/prerm" \
	"$BASE/Makefile:Package/apn-autoconfig/postrm"
do
	makefile="${package_hook%%:*}"
	hook="${package_hook#*:}"
	script="$TESTROOT/offline-hook.sh"
	extract_hook "$makefile" "$hook" >"$script"
	[ -s "$script" ] || fail "could not extract $hook"
	: >"$RECORD"
	RECORD_FILE="$RECORD" IPKG_INSTROOT="$SANDBOX" PATH="$MOCKBIN:$PATH" \
		sh "$script" >/dev/null 2>&1 || fail "$hook failed during an offline install"
	[ ! -s "$RECORD" ] || \
		fail "$hook touched the live system during an offline install: $(cat "$RECORD")"
done

# ---- live removal behaviour ----

live_postrm() {
	script="$TESTROOT/live-postrm.sh"
	extract_hook "$BASE/apn-autoconfig-modem/Makefile" 'Package/apn-autoconfig-modem/postrm' | \
		sed -e "s#/var/run/apn-autoconfig-modem#$SANDBOX/var/run/apn-autoconfig-modem#g" \
		    -e "s#/var/lock/apn-autoconfig-modem#$SANDBOX/var/lock/apn-autoconfig-modem#g" \
		    -e "s#/etc/config/apn-autoconfig-modem#$SANDBOX/etc/config/apn-autoconfig-modem#g" \
		>"$script"
	RECORD_FILE="$RECORD" sh "$script"
}

reset_sandbox() {
	rm -rf "$SANDBOX"
	mkdir -p "$SANDBOX/var/run/apn-autoconfig-modem/modems" \
		"$SANDBOX/var/run/apn-autoconfig-modem/provisioning" \
		"$SANDBOX/var/lock" "$SANDBOX/etc/config"
	printf 'first\nlast\n' >"$SANDBOX/var/run/apn-autoconfig-modem/modems/a-modem.tsv"
	printf 'v1\top\tmodem\tapnmodem1\t0\tnow\n' \
		>"$SANDBOX/var/run/apn-autoconfig-modem/provisioning/a-modem.tsv"
	printf "config apn_autoconfig_modem 'main'\n" >"$SANDBOX/etc/config/apn-autoconfig-modem"
}

printf '%s\n' 'TEST removal clears provisioning state as well as the inventory registry'
reset_sandbox
live_postrm
[ ! -e "$SANDBOX/var/run/apn-autoconfig-modem/provisioning/a-modem.tsv" ] || \
	fail 'removal left a provisioning baseline behind'
[ ! -e "$SANDBOX/var/run/apn-autoconfig-modem/modems/a-modem.tsv" ] || \
	fail 'removal left the inventory registry behind'
[ ! -d "$SANDBOX/var/run/apn-autoconfig-modem" ] || \
	fail 'removal left its state directory behind'

printf '%s\n' 'TEST removal never deletes a section this package created'
reset_sandbox
: >"$RECORD"
live_postrm
if grep -q 'uci .*delete' "$RECORD" 2>/dev/null; then
	fail 'removal deleted UCI configuration; project-owned sections must keep working'
fi

printf '%s\n' 'TEST removal preserves a lock held by a live operation'
reset_sandbox
/bin/sleep 30 &
live_pid=$!
printf '%s\n' "$live_pid" >"$SANDBOX/var/lock/apn-autoconfig-modem.live"
mkdir -p "$SANDBOX/var/lock/apn-autoconfig-modem.legacy-live"
printf '%s\n' "$live_pid" >"$SANDBOX/var/lock/apn-autoconfig-modem.legacy-live/pid"
live_postrm
[ -e "$SANDBOX/var/lock/apn-autoconfig-modem.live" ] || \
	fail 'removal erased a lock owned by a running operation'
[ -e "$SANDBOX/var/lock/apn-autoconfig-modem.legacy-live/pid" ] || \
	fail 'removal erased a live lock in the pre-0.10.1 directory representation'
kill "$live_pid" 2>/dev/null || :
wait "$live_pid" 2>/dev/null || :

printf '%s\n' 'TEST removal clears a provably stale lock in either representation'
reset_sandbox
dead_pid=999999
if kill -0 "$dead_pid" 2>/dev/null; then
	printf 'SKIP: PID %s is unexpectedly alive on this host\n' "$dead_pid"
else
	printf '%s\n' "$dead_pid" >"$SANDBOX/var/lock/apn-autoconfig-modem.stale"
	mkdir -p "$SANDBOX/var/lock/apn-autoconfig-modem.legacy-stale"
	printf '%s\n' "$dead_pid" >"$SANDBOX/var/lock/apn-autoconfig-modem.legacy-stale/pid"
	live_postrm
	[ ! -e "$SANDBOX/var/lock/apn-autoconfig-modem.stale" ] || \
		fail 'removal kept a stale lock file'
	[ ! -e "$SANDBOX/var/lock/apn-autoconfig-modem.legacy-stale" ] || \
		fail 'removal kept a stale lock directory'
fi

printf '%s\n' 'TEST removal never uses a wildcard that could erase an unrelated lock root'
reset_sandbox
mkdir -p "$SANDBOX/var/lock/apn-autoconfig.lock.d"
printf '%s\n' 1 >"$SANDBOX/var/lock/apn-autoconfig.lock"
printf 'unrelated\n' >"$SANDBOX/var/lock/some-other-package.lock"
live_postrm
[ -e "$SANDBOX/var/lock/some-other-package.lock" ] || \
	fail 'removal deleted a lock belonging to another package'
[ -e "$SANDBOX/var/lock/apn-autoconfig.lock" ] || \
	fail 'the modem package removed the APN engine operation lock'

printf '%s\n' 'TEST removal takes the package configuration with it'
reset_sandbox
live_postrm
[ ! -e "$SANDBOX/etc/config/apn-autoconfig-modem" ] || \
	fail 'removal left its own configuration behind'

printf '%s\n' 'All package lifecycle tests passed.'
