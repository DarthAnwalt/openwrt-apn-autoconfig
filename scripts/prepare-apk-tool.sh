#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/openwrt-sdk-config.sh"

BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build}"
DOWNLOAD="$BUILD_ROOT/$SDK_NAME"
EXTRACT="$BUILD_ROOT/repository-sdk"

[ "$(uname -s)" = "Linux" ] || {
	printf '%s\n' 'The official OpenWrt SDK requires Linux.' >&2
	exit 1
}
[ "$(uname -m)" = "x86_64" ] || {
	printf '%s\n' 'The official OpenWrt SDK requires Linux x86_64.' >&2
	exit 1
}

command -v curl >/dev/null 2>&1 || { printf '%s\n' 'curl is required' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '%s\n' 'sha256sum is required' >&2; exit 1; }
command -v unzstd >/dev/null 2>&1 || { printf '%s\n' 'unzstd is required' >&2; exit 1; }

mkdir -p "$BUILD_ROOT"
if [ ! -f "$DOWNLOAD" ]; then
	curl -fL --retry 3 -o "$DOWNLOAD" "$SDK_URL"
fi
printf '%s  %s\n' "$SDK_SHA256" "$DOWNLOAD" | sha256sum -c - >&2

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
tar --use-compress-program=unzstd -xf "$DOWNLOAD" -C "$EXTRACT"

APK_TOOL="$(find "$EXTRACT" -path '*/staging_dir/host/bin/apk' -type f | head -n 1)"
[ -n "$APK_TOOL" ] && [ -x "$APK_TOOL" ] || {
	printf '%s\n' 'The SDK apk v3 tool was not found.' >&2
	exit 1
}
printf '%s\n' "$APK_TOOL"
