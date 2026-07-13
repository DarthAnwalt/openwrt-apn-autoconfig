#!/bin/sh
set -eu

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
TARGET="${TARGET:-mediatek}"
SUBTARGET="${SUBTARGET:-filogic}"
SDK_SHA256="${SDK_SHA256:-ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25}"
SDK_NAME="openwrt-sdk-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
SDK_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/${SDK_NAME}"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build}"
DOWNLOAD="$BUILD_ROOT/$SDK_NAME"
EXTRACT="$BUILD_ROOT/sdk"
OUTPUT="$ROOT/dist"

[ "$(uname -s)" = "Linux" ] || {
	printf '%s\n' 'The official OpenWrt SDK is a Linux x86_64 build.' >&2
	printf '%s\n' 'Use the included GitHub Actions workflow on macOS.' >&2
	exit 1
}
[ "$(uname -m)" = "x86_64" ] || {
	printf '%s\n' 'This build script currently requires Linux x86_64.' >&2
	exit 1
}

command -v curl >/dev/null 2>&1 || { printf '%s\n' 'curl is required' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '%s\n' 'sha256sum is required' >&2; exit 1; }
command -v unzstd >/dev/null 2>&1 || { printf '%s\n' 'unzstd is required' >&2; exit 1; }

mkdir -p "$BUILD_ROOT" "$OUTPUT"
if [ ! -f "$DOWNLOAD" ]; then
	curl -fL --retry 3 -o "$DOWNLOAD" "$SDK_URL"
fi
printf '%s  %s\n' "$SDK_SHA256" "$DOWNLOAD" | sha256sum -c -

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
tar --use-compress-program=unzstd -xf "$DOWNLOAD" -C "$EXTRACT"
SDK_DIR="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$SDK_DIR" ] || { printf '%s\n' 'SDK extraction failed' >&2; exit 1; }

rm -rf "$SDK_DIR/package/apn-autoconfig"
mkdir -p "$SDK_DIR/package/apn-autoconfig"
cp -R "$ROOT/Makefile" "$ROOT/LICENSE" "$ROOT/files" "$SDK_DIR/package/apn-autoconfig/"

(
	cd "$SDK_DIR"
	printf '%s\n' 'CONFIG_PACKAGE_apn-autoconfig=m' >>.config
	make defconfig
	make package/apn-autoconfig/clean
	make package/apn-autoconfig/compile V=s
)

rm -f "$OUTPUT"/apn-autoconfig-*.apk
find "$SDK_DIR/bin" -type f -name 'apn-autoconfig-*.apk' -exec cp {} "$OUTPUT/" \;
set -- "$OUTPUT"/apn-autoconfig-*.apk
[ -f "$1" ] || { printf '%s\n' 'No APK was produced' >&2; exit 1; }
(cd "$OUTPUT" && sha256sum apn-autoconfig-*.apk >SHA256SUMS)
printf 'Built package(s):\n'
find "$OUTPUT" -maxdepth 1 -type f -print
