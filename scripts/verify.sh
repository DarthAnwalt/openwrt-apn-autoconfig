#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

sh -n "$ROOT/files/usr/sbin/apn-autoconfig"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-boot"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-action"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-query"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-control"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-database"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-qmi"
sh -n "$ROOT/files/etc/init.d/apn-autoconfig"
sh -n "$ROOT/files/etc/hotplug.d/button/50-apn-autoconfig"
sh -n "$ROOT/tests/run-tests.sh"
sh -n "$ROOT/tests/test-database-update.sh"
sh -n "$ROOT/scripts/build-with-sdk.sh"
sh -n "$ROOT/scripts/build-repository.sh"
sh -n "$ROOT/scripts/install.sh"
sh -n "$ROOT/scripts/openwrt-sdk-config.sh"
sh -n "$ROOT/scripts/prepare-apk-tool.sh"
sh -n "$ROOT/scripts/refresh-providers.sh"
sh -n "$ROOT/scripts/update-providers.sh"
sh -n "$ROOT/scripts/verify.sh"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$ROOT/scripts/generate-providers.py"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$ROOT/scripts/refresh-provider-sources.py"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$ROOT/scripts/check-provider-update.py"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
	"$ROOT/scripts/verify-provider-source-licenses.py"

python3 -m json.tool "$ROOT/luci-app-apn-autoconfig/root/usr/share/luci/menu.d/luci-app-apn-autoconfig.json" >/dev/null
python3 -m json.tool "$ROOT/luci-app-apn-autoconfig/root/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json" >/dev/null
python3 -m json.tool "$ROOT/data/provider-sources.json" >/dev/null
python3 -m json.tool "$ROOT/data/providers-report.json" >/dev/null
[ -f "$ROOT/data/licenses/Apache-2.0.txt" ]
[ -f "$ROOT/data/licenses/MBPI-CC-PDDC.txt" ]
[ -f "$ROOT/apn-autoconfig-providers/NOTICE" ]
[ -f "$ROOT/luci-app-apn-autoconfig/LICENSE" ]
cmp "$ROOT/LICENSE" "$ROOT/luci-app-apn-autoconfig/LICENSE"
grep -F -q 'PKG_LICENSE:=Apache-2.0 AND CC-PDDC' "$ROOT/apn-autoconfig-providers/Makefile"
grep -F -q 'Copyright 2006, The Android Open Source Project' "$ROOT/apn-autoconfig-providers/NOTICE"
grep -F -q 'Copyright 2006, The Android Open Source Project' \
	"$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
[ -f "$ROOT/apn-autoconfig-providers/Makefile" ]
[ -f "$ROOT/apn-autoconfig-providers/VERSION" ]
[ -f "$ROOT/repository/public-key.pem" ]
openssl pkey -pubin -in "$ROOT/repository/public-key.pem" -noout
expected_public_key_sha256='0d4d6d383c84205c8fa16fafdf341ff80de24c63574a1d7d938cfb532fa458d3'
actual_public_key_sha256="$(sha256sum "$ROOT/repository/public-key.pem" | awk '{ print $1 }')"
[ "$actual_public_key_sha256" = "$expected_public_key_sha256" ] || {
	printf '%s\n' 'Unexpected APK repository public key fingerprint.' >&2
	exit 1
}
grep -q "KEY_SHA256=\"$expected_public_key_sha256\"" "$ROOT/scripts/install.sh" || {
	printf '%s\n' 'Installer does not pin the expected repository key fingerprint.' >&2
	exit 1
}
if grep -q -- '--allow-untrusted' "$ROOT/scripts/install.sh"; then
	printf '%s\n' 'Installer must never bypass APK repository trust.' >&2
	exit 1
fi
if find "$ROOT" -path "$ROOT/.git" -prune -o -type f \
	\( -name 'private-key.pem' -o -name '*.private.pem' -o -name '*.encrypted.pem' \) \
	-print | grep -q .; then
	printf '%s\n' 'Private APK signing material exists inside the repository.' >&2
	exit 1
fi
database_version="$(sed -n '1p' "$ROOT/apn-autoconfig-providers/VERSION")"
core_version="$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/Makefile")"
luci_version="$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/luci-app-apn-autoconfig/Makefile")"
[ -n "$core_version" ]
[ -n "$luci_version" ]
grep -F -q "## apn-autoconfig $core_version / apn-autoconfig-providers $database_version / luci-app-apn-autoconfig $luci_version" \
	"$ROOT/CHANGELOG.md"
grep -F -q "./apn-autoconfig-$core_version-r1.apk" "$ROOT/README.md"
grep -F -q "./luci-app-apn-autoconfig-$luci_version-r1.apk" "$ROOT/README.md"
if [ -n "${EXPECTED_RELEASE_TAG:-}" ] && [ "$EXPECTED_RELEASE_TAG" != "v$core_version" ]; then
	printf 'Release tag %s does not match core package version %s.\n' \
		"$EXPECTED_RELEASE_TAG" "$core_version" >&2
	exit 1
fi
grep -F -q "# database-version: $database_version" \
	"$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["database_version"] == sys.argv[2]' \
	"$ROOT/data/providers-report.json" "$database_version"
grep -F -q 'DEPENDS:=+apn-autoconfig-providers ' "$ROOT/Makefile"
grep -F -q '+jsonfilter ' "$ROOT/Makefile"
grep -F -q 'DEPENDS:=+apn-autoconfig +kmod-button-hotplug' "$ROOT/Makefile"
[ -f "$ROOT/files/usr/share/apn-autoconfig/integrations/huasifei-wh3000" ]
[ "$(sed -n '1p' "$ROOT/files/usr/share/apn-autoconfig/integrations/huasifei-wh3000")" = \
	'huasifei-wh3000-gpio-v1' ]
core_depends="$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$ROOT/Makefile" | sed -n '1p')"
case "$core_depends" in
	*modemmanager*|*uqmi*|*umbim*|*kmod-button-hotplug*)
		printf '%s\n' 'The GUI-independent core has a backend- or board-specific hard dependency.' >&2
		exit 1
	;;
esac
if grep -F -q 'providers.tsv' "$ROOT/Makefile"; then
	printf '%s\n' 'The core package still owns the provider database.' >&2
	exit 1
fi
if command -v node >/dev/null 2>&1; then
	node --check "$ROOT/luci-app-apn-autoconfig/htdocs/luci-static/resources/view/network/apn-autoconfig.js"
	node "$ROOT/tests/test-luci-roaming-policy.js"
elif [ "${CI:-}" = true ] || [ -n "${EXPECTED_RELEASE_TAG:-}" ]; then
	printf '%s\n' 'Node.js is required for LuCI verification in CI and release builds.' >&2
	exit 1
fi
grep -F -q "form.Flag, 'autostart'" \
	"$ROOT/luci-app-apn-autoconfig/htdocs/luci-static/resources/view/network/apn-autoconfig.js"
grep -F -q 'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9 # v5' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/deploy-pages@cd2ce8fcbc39b97be8ca5fce6e763baed58fa128 # v5' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7' "$ROOT/.github/workflows/update-provider-database.yml"
grep -F -q 'ref: ${{ inputs.release_tag || github.ref }}' "$ROOT/.github/workflows/build.yml"
grep -F -q 'gh release create "$RELEASE_TAG"' "$ROOT/.github/workflows/build.yml"
grep -F -q -- '--verify-tag' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions: write' "$ROOT/.github/workflows/update-provider-database.yml"
grep -F -q 'publish_repository=true' "$ROOT/.github/workflows/update-provider-database.yml"
if grep -R -E 'uses:[[:space:]]+actions/[^@]+@v[0-9]+' "$ROOT/.github/workflows"; then
	printf '%s\n' 'A GitHub-maintained Action is not pinned to an immutable commit.' >&2
	exit 1
fi

awk -F '\t' '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
	NF != 12 { print "invalid TSV field count at line " NR > "/dev/stderr"; bad=1 }
	$1 !~ /^[0-9][0-9][0-9][0-9][0-9][0-9]?$/ { print "invalid MCC/MNC at line " NR > "/dev/stderr"; bad=1 }
	$7 !~ /^[A-Za-z0-9._-]+$/ { print "invalid APN at line " NR > "/dev/stderr"; bad=1 }
	$8 !~ /^[0-9]+$/ { print "invalid priority at line " NR > "/dev/stderr"; bad=1 }
	END { exit bad }
' "$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"

sh "$ROOT/tests/test-provider-generator.sh"
sh "$ROOT/tests/test-database-update.sh"
sh "$ROOT/tests/test-installer.sh"
sh "$ROOT/tests/run-tests.sh"
printf '%s\n' 'Static and behavioral verification passed.'
