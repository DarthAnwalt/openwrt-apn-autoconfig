#!/bin/sh
set -eu

PROG="apn-autoconfig-installer"
FEED_URL="https://darthanwalt.github.io/openwrt-apn-autoconfig/25.12/noarch/packages.adb"
KEY_URL="https://darthanwalt.github.io/openwrt-apn-autoconfig/public-key.pem"
KEY_SHA256="0d4d6d383c84205c8fa16fafdf341ff80de24c63574a1d7d938cfb532fa458d3"
SYSTEM_ROOT="${APN_INSTALLER_ROOT:-}"
APK="${APN_INSTALLER_APK:-apk}"
OPENWRT_RELEASE_FILE="$SYSTEM_ROOT/etc/openwrt_release"
KEYS_DIR="$SYSTEM_ROOT/etc/apk/keys"
KEY_DEST="$KEYS_DIR/apn-autoconfig.pem"
REPOSITORIES_FILE="$SYSTEM_ROOT/etc/apk/repositories"
REPOSITORIES_DIR="$SYSTEM_ROOT/etc/apk/repositories.d"
REPOSITORY_DEST="$REPOSITORIES_DIR/apn-autoconfig.list"
TMP_BASE=""
DRY_RUN=0
INSTALL_LUCI=""

usage() {
	cat <<'EOF'
Usage: install.sh [--dry-run] [--gui|--nogui]

  --dry-run       Verify the key and signed repositories and simulate install.
  --gui           Install the LuCI application plus its core dependencies.
  --nogui         Install only the command-line core and provider database.
  -h, --help      Show this help.

Without --gui or --nogui, an interactive terminal prompt asks
whether the LuCI web interface should be installed.
EOF
}

fail() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

cleanup() {
	[ -z "$TMP_BASE" ] || rm -rf "$TMP_BASE"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--gui)
			[ "$INSTALL_LUCI" != no ] || fail '--gui conflicts with --nogui'
			INSTALL_LUCI=yes
		;;
		--nogui)
			[ "$INSTALL_LUCI" != yes ] || fail '--nogui conflicts with --gui'
			INSTALL_LUCI=no
		;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; fail "unknown option: $1" ;;
	esac
	shift
done

[ "$(id -u 2>/dev/null || printf '%s' 1)" = 0 ] ||
	fail 'run this installer as root'
[ -r "$OPENWRT_RELEASE_FILE" ] || fail 'this does not appear to be an OpenWrt system'

DISTRIB_RELEASE=""
# The OpenWrt release file is root-owned system configuration.
# shellcheck disable=SC1090
. "$OPENWRT_RELEASE_FILE"
case "${DISTRIB_RELEASE:-}" in
	25.12|25.12.*) : ;;
	*) fail "OpenWrt 25.12 is required; found ${DISTRIB_RELEASE:-unknown}" ;;
esac

command -v "$APK" >/dev/null 2>&1 || fail 'OpenWrt apk v3 is required'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
command -v mktemp >/dev/null 2>&1 || fail 'mktemp is required'

if [ -z "$INSTALL_LUCI" ]; then
	[ -r /dev/tty ] ||
		fail 'no interactive terminal; pass --gui or --nogui'
	printf 'Install the LuCI web interface? [Y/n] ' >/dev/tty
	IFS= read -r answer </dev/tty || fail 'could not read the LuCI selection'
	case "$answer" in
		''|y|Y|yes|YES|Yes) INSTALL_LUCI=yes ;;
		n|N|no|NO|No) INSTALL_LUCI=no ;;
		*) fail "invalid answer: $answer" ;;
	esac
fi

case "$INSTALL_LUCI" in
	yes)
		TARGET_PACKAGE='luci-app-apn-autoconfig'
		INSTALL_DESCRIPTION='core, provider database and LuCI web interface'
	;;
	no)
		TARGET_PACKAGE='apn-autoconfig'
		INSTALL_DESCRIPTION='command-line core and provider database (without LuCI)'
	;;
esac

download() {
	url="$1"
	output="$2"
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$output" "$url"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$output" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$output"
	else
		fail 'wget, uclient-fetch or curl is required'
	fi
}

append_repository_file() {
	file="$1"
	[ -f "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		printf '%s\n' "$line" >>"$TEMP_REPOSITORIES"
	done <"$file"
}

feed_is_configured() {
	for file in "$REPOSITORIES_FILE" "$REPOSITORIES_DIR"/*; do
		[ -f "$file" ] || continue
		grep -qxF "$FEED_URL" "$file" && return 0
	done
	return 1
}

trusted_key_exists() {
	for key in "$KEYS_DIR"/*; do
		[ -f "$key" ] || continue
		fingerprint="$(sha256sum "$key" 2>/dev/null | awk '{ print $1 }')"
		[ "$fingerprint" = "$KEY_SHA256" ] && return 0
	done
	return 1
}

TMP_BASE="$(mktemp -d /tmp/apn-autoconfig-installer.XXXXXX)" ||
	fail 'could not create a temporary workspace'
TEMP_KEYS="$TMP_BASE/keys"
TEMP_CACHE="$TMP_BASE/cache"
TEMP_REPOSITORIES="$TMP_BASE/repositories"
DOWNLOADED_KEY="$TMP_BASE/apn-autoconfig.pem"
mkdir -m 0700 "$TEMP_KEYS" "$TEMP_CACHE"
: >"$TEMP_REPOSITORIES"

printf 'APN Auto-Config installer\n'
printf 'Planned installation: %s\n' "$INSTALL_DESCRIPTION"
printf 'Downloading and verifying the repository public key...\n'
download "$KEY_URL" "$DOWNLOADED_KEY" || fail 'could not download the public key'
downloaded_fingerprint="$(sha256sum "$DOWNLOADED_KEY" | awk '{ print $1 }')"
[ "$downloaded_fingerprint" = "$KEY_SHA256" ] ||
	fail 'the downloaded repository key has an unexpected SHA-256 fingerprint'

for key in "$KEYS_DIR"/*; do
	[ -f "$key" ] || continue
	cp "$key" "$TEMP_KEYS/$(basename "$key")"
done
cp "$DOWNLOADED_KEY" "$TEMP_KEYS/apn-autoconfig.pem"

append_repository_file "$REPOSITORIES_FILE"
for file in "$REPOSITORIES_DIR"/*; do
	append_repository_file "$file"
done
grep -qxF "$FEED_URL" "$TEMP_REPOSITORIES" 2>/dev/null ||
	printf '%s\n' "$FEED_URL" >>"$TEMP_REPOSITORIES"

printf 'Refreshing repositories in an isolated temporary workspace...\n'
"$APK" --keys-dir "$TEMP_KEYS" --repositories-file "$TEMP_REPOSITORIES" \
	--cache-dir "$TEMP_CACHE" --force-refresh update
printf 'Simulating installation of %s...\n' "$TARGET_PACKAGE"
"$APK" --keys-dir "$TEMP_KEYS" --repositories-file "$TEMP_REPOSITORIES" \
	--cache-dir "$TEMP_CACHE" add --simulate "$TARGET_PACKAGE"

if [ "$DRY_RUN" -eq 1 ]; then
	printf '\nDry run completed successfully; no persistent files were changed.\n'
	printf 'Run the installer again without --dry-run to install %s.\n' "$INSTALL_DESCRIPTION"
	exit 0
fi

if [ -e "$KEY_DEST" ]; then
	existing_fingerprint="$(sha256sum "$KEY_DEST" 2>/dev/null | awk '{ print $1 }')"
	[ "$existing_fingerprint" = "$KEY_SHA256" ] ||
		fail "$KEY_DEST exists with an unexpected fingerprint; refusing to overwrite it"
elif trusted_key_exists; then
	printf 'The trusted repository key is already installed.\n'
else
	mkdir -p "$KEYS_DIR"
	temporary_key="$KEY_DEST.tmp.$$"
	cp "$DOWNLOADED_KEY" "$temporary_key"
	chmod 0644 "$temporary_key"
	mv "$temporary_key" "$KEY_DEST"
	printf 'Installed the pinned repository key at %s.\n' "$KEY_DEST"
fi

if feed_is_configured; then
	printf 'The signed APN Auto-Config feed is already configured.\n'
else
	mkdir -p "$REPOSITORIES_DIR"
	[ ! -e "$REPOSITORY_DEST" ] ||
		fail "$REPOSITORY_DEST already exists without the expected feed"
	temporary_repository="$REPOSITORY_DEST.tmp.$$"
	printf '%s\n' "$FEED_URL" >"$temporary_repository"
	chmod 0644 "$temporary_repository"
	mv "$temporary_repository" "$REPOSITORY_DEST"
	printf 'Configured the signed feed at %s.\n' "$REPOSITORY_DEST"
fi

"$APK" update
"$APK" add "$TARGET_PACKAGE"

printf '\nInstallation completed successfully.\n'
printf 'Automatic APN reconciliation and the hardware button remain disabled by default.\n'
if [ "$INSTALL_LUCI" = yes ]; then
	printf 'Open LuCI and navigate to Network -> APN Auto-Config.\n'
else
	printf 'Run `apn-autoconfig status` to inspect the current mobile profile.\n'
fi
