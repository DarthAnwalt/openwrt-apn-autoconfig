#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/install.sh"
TMP="${TMPDIR:-/tmp}/apn-autoconfig-installer-test.$$"
BIN="$TMP/bin"
ROOTFS="$TMP/root"
APK_LOG="$TMP/apk.log"

cleanup() {
	rm -rf "$TMP"
}
trap cleanup 0 HUP INT TERM

mkdir -p "$BIN"

cat >"$BIN/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] && { printf '%s\n' 0; exit 0; }
exit 1
EOF

cat >"$BIN/wget" <<'EOF'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		-q) shift ;;
		-O) output="$2"; shift 2 ;;
		*) shift ;;
	esac
done
[ -n "$output" ] || exit 2
cp "$FIXTURE_KEY" "$output"
EOF

cat >"$BIN/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$APK_LOG"
exit 0
EOF
chmod 0755 "$BIN"/*

export PATH="$BIN:$PATH"
export FIXTURE_KEY="$ROOT/repository/public-key.pem"
export APK_LOG
export APN_INSTALLER_APK="$BIN/apk"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

prepare_root() {
	rm -rf "$ROOTFS"
	mkdir -p "$ROOTFS/etc/apk/keys" "$ROOTFS/etc/apk/repositories.d"
	cat >"$ROOTFS/etc/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.5'
EOF
	printf '%s\n' 'https://example.invalid/openwrt/packages.adb' >"$ROOTFS/etc/apk/repositories"
	: >"$APK_LOG"
}

run_installer() {
	APN_INSTALLER_ROOT="$ROOTFS" sh "$SCRIPT" "$@"
}

workspace_snapshot() {
	find /tmp -maxdepth 1 -type d -name 'apn-autoconfig-installer.*' -print | sort
}

printf '%s\n' 'TEST dry run without LuCI verifies and simulates without persistent changes'
prepare_root
workspaces_before="$(workspace_snapshot)"
run_installer --dry-run --nogui >/dev/null
workspaces_after="$(workspace_snapshot)"
[ ! -e "$ROOTFS/etc/apk/keys/apn-autoconfig.pem" ] || fail 'dry run installed a key'
[ ! -e "$ROOTFS/etc/apk/repositories.d/apn-autoconfig.list" ] || fail 'dry run installed a repository'
grep -q -- 'add --simulate apn-autoconfig$' "$APK_LOG" || fail 'CLI package was not simulated'
[ "$workspaces_before" = "$workspaces_after" ] || fail 'installer workspace was not removed'

printf '%s\n' 'TEST installation with LuCI adds the pinned key, dedicated feed and GUI package'
prepare_root
run_installer --gui >/dev/null
[ "$(sha256sum "$ROOTFS/etc/apk/keys/apn-autoconfig.pem" | awk '{ print $1 }')" = \
	'0d4d6d383c84205c8fa16fafdf341ff80de24c63574a1d7d938cfb532fa458d3' ] ||
	fail 'installed key fingerprint differs'
grep -qxF 'https://darthanwalt.github.io/openwrt-apn-autoconfig/25.12/noarch/packages.adb' \
	"$ROOTFS/etc/apk/repositories.d/apn-autoconfig.list" || fail 'dedicated feed was not installed'
grep -q -- 'add --simulate luci-app-apn-autoconfig$' "$APK_LOG" || fail 'LuCI package was not simulated'
grep -q -- '^update$' "$APK_LOG" || fail 'system repositories were not refreshed for installation'
grep -q -- '^add luci-app-apn-autoconfig$' "$APK_LOG" || fail 'LuCI package was not installed'

printf '%s\n' 'TEST repeated installation reuses the trusted key and configured feed'
run_installer --gui >/dev/null
[ "$(grep -c '^https://darthanwalt.github.io/openwrt-apn-autoconfig/25.12/noarch/packages.adb$' \
	"$ROOTFS/etc/apk/repositories.d/apn-autoconfig.list")" -eq 1 ] || fail 'feed was duplicated'

printf '%s\n' 'TEST an existing conflicting key is never overwritten'
prepare_root
printf '%s\n' 'unexpected key' >"$ROOTFS/etc/apk/keys/apn-autoconfig.pem"
if run_installer --nogui >/dev/null 2>&1; then
	fail 'installer overwrote a conflicting key'
fi
grep -qxF 'unexpected key' "$ROOTFS/etc/apk/keys/apn-autoconfig.pem" ||
	fail 'conflicting key contents changed'

printf '%s\n' 'TEST a downloaded key with the wrong fingerprint is rejected before apk runs'
prepare_root
printf '%s\n' 'substituted download' >"$TMP/unexpected-public-key.pem"
FIXTURE_KEY="$TMP/unexpected-public-key.pem"
export FIXTURE_KEY
if run_installer --nogui >/dev/null 2>&1; then
	fail 'downloaded key with the wrong fingerprint was accepted'
fi
[ ! -s "$APK_LOG" ] || fail 'apk ran after a downloaded key fingerprint mismatch'
FIXTURE_KEY="$ROOT/repository/public-key.pem"
export FIXTURE_KEY

printf '%s\n' 'TEST unsupported OpenWrt releases are rejected before downloading'
prepare_root
sed -i.bak "s/25.12.5/24.10.0/" "$ROOTFS/etc/openwrt_release"
if run_installer --nogui >/dev/null 2>&1; then
	fail 'unsupported OpenWrt release was accepted'
fi
[ ! -s "$APK_LOG" ] || fail 'apk ran on an unsupported OpenWrt release'

printf '%s\n' 'TEST explicit LuCI choices are mutually exclusive'
prepare_root
if run_installer --gui --nogui >/dev/null 2>&1; then
	fail 'conflicting LuCI choices were accepted'
fi

printf '%s\n' 'Installer tests passed.'
