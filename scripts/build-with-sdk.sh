#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/openwrt-sdk-config.sh"

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
rm -rf "$SDK_DIR/package/apn-autoconfig-providers"
cp -R "$ROOT/apn-autoconfig-providers" "$SDK_DIR/package/apn-autoconfig-providers"
mkdir -p "$SDK_DIR/package/apn-autoconfig-providers/licenses"
cp "$ROOT/data/licenses/Apache-2.0.txt" "$ROOT/data/licenses/MBPI-CC-PDDC.txt" \
	"$SDK_DIR/package/apn-autoconfig-providers/licenses/"
rm -rf "$SDK_DIR/package/luci-app-apn-autoconfig"
cp -R "$ROOT/luci-app-apn-autoconfig" "$SDK_DIR/package/luci-app-apn-autoconfig"

(
	cd "$SDK_DIR"
	printf '%s\n' 'CONFIG_PACKAGE_apn-autoconfig=m' >>.config
	printf '%s\n' 'CONFIG_PACKAGE_apn-autoconfig-providers=m' >>.config
	printf '%s\n' 'CONFIG_PACKAGE_luci-app-apn-autoconfig=m' >>.config
	make defconfig
	make package/apn-autoconfig-providers/clean
	make package/apn-autoconfig-providers/compile V=s
	make package/apn-autoconfig/clean
	make package/apn-autoconfig/compile V=s
	make package/luci-app-apn-autoconfig/clean
	make package/luci-app-apn-autoconfig/compile V=s
)

rm -f "$OUTPUT"/apn-autoconfig-[0-9]*.apk \
	"$OUTPUT"/apn-autoconfig-providers-*.apk \
	"$OUTPUT"/luci-app-apn-autoconfig-*.apk
find "$SDK_DIR/bin" -type f -name 'apn-autoconfig-[0-9]*.apk' -exec cp {} "$OUTPUT/" \;
find "$SDK_DIR/bin" -type f -name 'apn-autoconfig-providers-*.apk' -exec cp {} "$OUTPUT/" \;
find "$SDK_DIR/bin" -type f -name 'luci-app-apn-autoconfig-*.apk' -exec cp {} "$OUTPUT/" \;
set -- "$OUTPUT"/apn-autoconfig-[0-9]*.apk \
	"$OUTPUT"/apn-autoconfig-providers-*.apk \
	"$OUTPUT"/luci-app-apn-autoconfig-*.apk
[ -f "$1" ] && [ -f "$2" ] && [ -f "$3" ] || {
	printf '%s\n' 'One or more APKs were not produced' >&2
	exit 1
}

APK_TOOL="$SDK_DIR/staging_dir/host/bin/apk"
[ -x "$APK_TOOL" ] || { printf '%s\n' 'SDK apk v3 inspection tool was not found' >&2; exit 1; }

inspect_package() {
	package="$1"
	name="$2"
	expected_count="$3"
	shift 3
	inspect_root="$BUILD_ROOT/inspect-$name"
	metadata="$BUILD_ROOT/$name-adbdump.json"

	rm -rf "$inspect_root"
	mkdir -p "$inspect_root"
	"$APK_TOOL" adbdump --format json "$package" >"$metadata"
	(
		cd "$inspect_root"
		"$APK_TOOL" extract --allow-untrusted "$package" >/dev/null
	)

	grep -E -q '"name"[[:space:]]*:[[:space:]]*"'"$name"'"' "$metadata" || {
		printf 'Unexpected package name metadata in %s\n' "$package" >&2
		cat "$metadata" >&2
		exit 1
	}
	grep -E -q '"arch"[[:space:]]*:[[:space:]]*"noarch"' "$metadata" || {
		printf 'Package is not architecture-independent: %s\n' "$package" >&2
		cat "$metadata" >&2
		exit 1
	}

	actual_count="$(find "$inspect_root" -type f | wc -l | tr -d ' ')"
	[ "$actual_count" = "$expected_count" ] || {
		printf 'Unexpected file count in %s: expected %s, found %s\n' \
			"$package" "$expected_count" "$actual_count" >&2
		find "$inspect_root" -type f -print >&2
		exit 1
	}
	for path do
		[ -f "$inspect_root/$path" ] || {
			printf 'Required package file is missing from %s: /%s\n' "$package" "$path" >&2
			exit 1
		}
	done
}

inspect_package "$1" apn-autoconfig 13 \
	usr/sbin/apn-autoconfig \
	usr/libexec/apn-autoconfig-boot \
	usr/libexec/apn-autoconfig-action \
	usr/libexec/apn-autoconfig-query \
	usr/libexec/apn-autoconfig-control \
	usr/libexec/apn-autoconfig-database \
	etc/config/apn-autoconfig \
	etc/init.d/apn-autoconfig \
	etc/hotplug.d/button/50-apn-autoconfig \
	usr/share/licenses/apn-autoconfig/LICENSE \
	lib/apk/packages/apn-autoconfig.list \
	lib/apk/packages/apn-autoconfig.conffiles \
	lib/apk/packages/apn-autoconfig.conffiles_static

inspect_package "$2" apn-autoconfig-providers 5 \
	usr/share/apn-autoconfig/providers.tsv \
	usr/share/licenses/apn-autoconfig-providers/Apache-2.0.txt \
	usr/share/licenses/apn-autoconfig-providers/MBPI-CC-PDDC.txt \
	usr/share/licenses/apn-autoconfig-providers/NOTICE \
	lib/apk/packages/apn-autoconfig-providers.list

grep -F -q '/etc/config/apn-autoconfig' \
	"$BUILD_ROOT/inspect-apn-autoconfig/lib/apk/packages/apn-autoconfig.conffiles"
grep -F -q '/etc/config/apn-autoconfig ' \
	"$BUILD_ROOT/inspect-apn-autoconfig/lib/apk/packages/apn-autoconfig.conffiles_static"

for executable in \
	usr/sbin/apn-autoconfig \
	usr/libexec/apn-autoconfig-boot \
	usr/libexec/apn-autoconfig-action \
	usr/libexec/apn-autoconfig-query \
	usr/libexec/apn-autoconfig-control \
	usr/libexec/apn-autoconfig-database \
	etc/init.d/apn-autoconfig \
	etc/hotplug.d/button/50-apn-autoconfig
do
	[ -x "$BUILD_ROOT/inspect-apn-autoconfig/$executable" ] || {
		printf 'Package file is not executable: /%s\n' "$executable" >&2
		exit 1
	}
done

inspect_package "$3" luci-app-apn-autoconfig 5 \
	www/luci-static/resources/view/network/apn-autoconfig.js \
	usr/share/luci/menu.d/luci-app-apn-autoconfig.json \
	usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json \
	usr/share/licenses/luci-app-apn-autoconfig/LICENSE \
	lib/apk/packages/luci-app-apn-autoconfig.list

(cd "$OUTPUT" && sha256sum \
	apn-autoconfig-[0-9]*.apk \
	apn-autoconfig-providers-*.apk \
	luci-app-apn-autoconfig-*.apk >SHA256SUMS)
printf 'Built package(s):\n'
find "$OUTPUT" -maxdepth 1 -type f -print
