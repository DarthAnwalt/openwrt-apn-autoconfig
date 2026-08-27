#!/bin/sh
set -eu

# Build only the independently versioned public provider database package.
# This is intentionally separate from build-with-sdk.sh: a provider refresh
# must not rebuild private-development packages merely because an upstream XML
# file changed.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/openwrt-sdk-config.sh"

BUILD_ROOT="${BUILD_ROOT:-$ROOT/.build/provider}"
DOWNLOAD="$BUILD_ROOT/$SDK_NAME"
EXTRACT="$BUILD_ROOT/sdk"
OUTPUT="${PROVIDER_OUTPUT_DIR:-$ROOT/dist/provider}"

fail() { printf 'Provider build failed: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail 'the official OpenWrt SDK requires Linux'
[ "$(uname -m)" = x86_64 ] || fail 'the official OpenWrt SDK requires x86_64'
for command_name in curl sha256sum unzstd; do
	command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

mkdir -p "$BUILD_ROOT" "$OUTPUT"
if [ ! -f "$DOWNLOAD" ]; then
	curl -fL --retry 3 -o "$DOWNLOAD" "$SDK_URL"
fi
printf '%s  %s\n' "$SDK_SHA256" "$DOWNLOAD" | sha256sum -c -

rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
tar --use-compress-program=unzstd -xf "$DOWNLOAD" -C "$EXTRACT"
SDK_DIR="$(find "$EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$SDK_DIR" ] || fail 'SDK extraction failed'

PACKAGE="$SDK_DIR/package/apn-autoconfig-providers"
rm -rf "$PACKAGE"
cp -R "$ROOT/apn-autoconfig-providers" "$PACKAGE"
mkdir -p "$PACKAGE/licenses"
cp "$ROOT/data/licenses/Apache-2.0.txt" "$ROOT/data/licenses/MBPI-CC-PDDC.txt" \
	"$PACKAGE/licenses/"

(
	cd "$SDK_DIR"
	printf '%s\n' 'CONFIG_PACKAGE_apn-autoconfig-providers=m' >>.config
	make defconfig
	make package/apn-autoconfig-providers/clean
	make package/apn-autoconfig-providers/compile V=s
)

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
find "$SDK_DIR/bin" -type f -name 'apn-autoconfig-providers-*.apk' -exec cp {} "$OUTPUT/" \;
set -- "$OUTPUT"/apn-autoconfig-providers-*.apk
[ "$#" -eq 1 ] && [ -f "$1" ] || fail 'expected exactly one provider APK'

APK_TOOL="$SDK_DIR/staging_dir/host/bin/apk"
[ -x "$APK_TOOL" ] || fail 'the SDK apk v3 inspection tool was not found'
INSPECT="$BUILD_ROOT/inspect"
rm -rf "$INSPECT"
mkdir -p "$INSPECT"
"$APK_TOOL" adbdump --format json "$1" >"$BUILD_ROOT/provider-adbdump.json"
( cd "$INSPECT" && "$APK_TOOL" extract --allow-untrusted "$1" >/dev/null )
grep -E -q '"name"[[:space:]]*:[[:space:]]*"apn-autoconfig-providers"' \
	"$BUILD_ROOT/provider-adbdump.json" || fail 'unexpected package name metadata'
grep -E -q '"arch"[[:space:]]*:[[:space:]]*"noarch"' \
	"$BUILD_ROOT/provider-adbdump.json" || fail 'provider package is not noarch'
[ "$(find "$INSPECT" -type f | wc -l | tr -d ' ')" = 5 ] || \
	fail 'provider package has an unexpected file set'
for required in \
	usr/share/apn-autoconfig/providers.tsv \
	usr/share/licenses/apn-autoconfig-providers/Apache-2.0.txt \
	usr/share/licenses/apn-autoconfig-providers/MBPI-CC-PDDC.txt \
	usr/share/licenses/apn-autoconfig-providers/NOTICE \
	lib/apk/packages/apn-autoconfig-providers.list
do
	[ -f "$INSPECT/$required" ] || fail "provider package is missing /$required"
done

sh "$ROOT/scripts/check-release-artifacts.sh" "$APK_TOOL" "$OUTPUT"
( cd "$OUTPUT" && sha256sum ./*.apk >SHA256SUMS )
printf 'Provider package built at %s\n' "$1"
