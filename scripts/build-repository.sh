#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGE_DIR="${PACKAGE_DIR:-$ROOT/dist}"
OUTPUT_DIR="$ROOT/dist/repository"
PUBLIC_KEY="${PUBLIC_KEY:-$ROOT/repository/public-key.pem}"
INSTALLER="$ROOT/scripts/install.sh"
SIGNING_KEY="${APK_SIGNING_KEY_FILE:-}"
OPENWRT_SERIES="${OPENWRT_SERIES:-25.12}"

fail() {
	printf 'Repository build failed: %s\n' "$*" >&2
	exit 1
}

[ -n "$SIGNING_KEY" ] || fail 'APK_SIGNING_KEY_FILE is not set'
[ -f "$SIGNING_KEY" ] || fail "signing key not found: $SIGNING_KEY"
[ -f "$PUBLIC_KEY" ] || fail "public key not found: $PUBLIC_KEY"
[ -f "$INSTALLER" ] || fail "installer not found: $INSTALLER"
command -v openssl >/dev/null 2>&1 || fail 'openssl is required'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'

if [ -n "${APK_TOOL:-}" ]; then
	:
else
	APK_TOOL="$(find "$ROOT/.build/sdk" -path '*/staging_dir/host/bin/apk' -type f 2>/dev/null | head -n 1)"
fi
[ -n "$APK_TOOL" ] && [ -x "$APK_TOOL" ] ||
	fail 'OpenWrt SDK apk v3 tool not found; set APK_TOOL'

single_package() {
	pattern="$1"
	set -- "$PACKAGE_DIR"/$pattern
	[ "$#" -eq 1 ] && [ -f "$1" ] ||
		fail "expected exactly one package matching $pattern in $PACKAGE_DIR"
	printf '%s\n' "$1"
}

CORE_PACKAGE="$(single_package 'apn-autoconfig-[0-9]*.apk')"
PROVIDER_PACKAGE="$(single_package 'apn-autoconfig-providers-*.apk')"
LUCI_PACKAGE="$(single_package 'luci-app-apn-autoconfig-*.apk')"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apn-autoconfig-repository.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM

DERIVED_PUBLIC_KEY="$WORK_DIR/public-key.pem"
openssl pkey -in "$SIGNING_KEY" -pubout -out "$DERIVED_PUBLIC_KEY" >/dev/null 2>&1 ||
	fail 'could not derive the public key from the signing key'
cmp -s "$DERIVED_PUBLIC_KEY" "$PUBLIC_KEY" ||
	fail 'the signing key does not match repository/public-key.pem'

SITE_DIR="$WORK_DIR/site"
FEED_DIR="$SITE_DIR/$OPENWRT_SERIES/noarch"
KEYS_DIR="$WORK_DIR/keys"
mkdir -p "$FEED_DIR" "$KEYS_DIR"
cp "$PUBLIC_KEY" "$SITE_DIR/public-key.pem"
cp "$INSTALLER" "$SITE_DIR/install.sh"
chmod 0755 "$SITE_DIR/install.sh"
cp "$PUBLIC_KEY" "$KEYS_DIR/apn-autoconfig.pem"
cp "$CORE_PACKAGE" "$PROVIDER_PACKAGE" "$LUCI_PACKAGE" "$FEED_DIR/"

(
	cd "$FEED_DIR"
	"$APK_TOOL" mkndx \
		--root "$WORK_DIR" \
		--keys-dir "$KEYS_DIR" \
		--allow-untrusted \
		--sign "$SIGNING_KEY" \
		--output packages.adb \
		*.apk
	"$APK_TOOL" adbdump --format json packages.adb >packages.json
)

for package_name in \
	apn-autoconfig \
	apn-autoconfig-providers \
	luci-app-apn-autoconfig
do
	grep -E -q '"name"[[:space:]]*:[[:space:]]*"'"$package_name"'"' \
		"$FEED_DIR/packages.json" ||
		fail "packages.adb does not contain $package_name"
done

# Verify the signed index and fetch a package payload using only the public key.
# Fetch deliberately avoids resolving dependencies from the official OpenWrt
# feeds, which are already present on a real router.
VERIFY_ROOT="$WORK_DIR/verify-root"
FETCH_DIR="$WORK_DIR/fetched"
mkdir -p "$VERIFY_ROOT" "$FETCH_DIR"
"$APK_TOOL" \
	--root "$VERIFY_ROOT" \
	--keys-dir "$KEYS_DIR" \
	--repositories-file /dev/null \
	--repository "file://$FEED_DIR/packages.adb" \
	--arch noarch \
	fetch --output "$FETCH_DIR" apn-autoconfig-providers >/dev/null
set -- "$FETCH_DIR"/apn-autoconfig-providers-*.apk
[ "$#" -eq 1 ] && [ -f "$1" ] ||
	fail 'APK fetch did not produce exactly one provider package'
cmp -s "$PROVIDER_PACKAGE" "$1" ||
	fail 'the package fetched through packages.adb differs from the built APK'

touch "$SITE_DIR/.nojekyll"
(
	cd "$SITE_DIR"
	sha256sum \
		install.sh \
		public-key.pem \
		"$OPENWRT_SERIES"/noarch/*.apk \
		"$OPENWRT_SERIES"/noarch/packages.adb \
		"$OPENWRT_SERIES"/noarch/packages.json >SHA256SUMS
	sha256sum public-key.pem | awk '{ print $1 }' >public-key.sha256
)

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
mv "$SITE_DIR" "$OUTPUT_DIR"
trap - EXIT HUP INT TERM
rm -rf "$WORK_DIR"

printf 'Signed APK repository created at %s\n' "$OUTPUT_DIR"
printf 'Public key SHA-256: '
cat "$OUTPUT_DIR/public-key.sha256"
