#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

sh -n "$ROOT/files/usr/sbin/apn-autoconfig"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-boot"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-action"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-query"
sh -n "$ROOT/files/usr/libexec/apn-autoconfig-control"
sh -n "$ROOT/files/etc/init.d/apn-autoconfig"
sh -n "$ROOT/files/etc/hotplug.d/button/50-apn-autoconfig"
sh -n "$ROOT/tests/run-tests.sh"
sh -n "$ROOT/scripts/build-with-sdk.sh"
sh -n "$ROOT/scripts/build-repository.sh"
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

python3 -m json.tool "$ROOT/luci-app-apn-autoconfig/root/usr/share/luci/menu.d/luci-app-apn-autoconfig.json" >/dev/null
python3 -m json.tool "$ROOT/luci-app-apn-autoconfig/root/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json" >/dev/null
python3 -m json.tool "$ROOT/data/provider-sources.json" >/dev/null
python3 -m json.tool "$ROOT/data/providers-report.json" >/dev/null
[ -f "$ROOT/data/licenses/Apache-2.0.txt" ]
[ -f "$ROOT/data/licenses/MBPI-CC-PD.txt" ]
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
if find "$ROOT" -path "$ROOT/.git" -prune -o -type f \
	\( -name 'private-key.pem' -o -name '*.private.pem' -o -name '*.encrypted.pem' \) \
	-print | grep -q .; then
	printf '%s\n' 'Private APK signing material exists inside the repository.' >&2
	exit 1
fi
database_version="$(sed -n '1p' "$ROOT/apn-autoconfig-providers/VERSION")"
grep -F -q "# database-version: $database_version" \
	"$ROOT/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["database_version"] == sys.argv[2]' \
	"$ROOT/data/providers-report.json" "$database_version"
grep -F -q 'DEPENDS:=+apn-autoconfig-providers ' "$ROOT/Makefile"
if grep -F -q 'providers.tsv' "$ROOT/Makefile"; then
	printf '%s\n' 'The core package still owns the provider database.' >&2
	exit 1
fi
if command -v node >/dev/null 2>&1; then
	node --check "$ROOT/luci-app-apn-autoconfig/htdocs/luci-static/resources/view/network/apn-autoconfig.js"
fi
grep -F -q "form.Flag, 'autostart'" \
	"$ROOT/luci-app-apn-autoconfig/htdocs/luci-static/resources/view/network/apn-autoconfig.js"
grep -F -q 'actions/checkout@v7' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/upload-artifact@v7' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/download-artifact@v8' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/upload-pages-artifact@v5' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/deploy-pages@v5' "$ROOT/.github/workflows/build.yml"
grep -F -q 'actions/checkout@v7' "$ROOT/.github/workflows/update-provider-database.yml"
grep -F -q 'actions: write' "$ROOT/.github/workflows/update-provider-database.yml"
grep -F -q 'publish_repository=true' "$ROOT/.github/workflows/update-provider-database.yml"
if grep -R -E 'actions/(checkout|upload-artifact|download-artifact)@v4' "$ROOT/.github/workflows"; then
	printf '%s\n' 'Legacy Node.js 20 GitHub Action remains configured.' >&2
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
sh "$ROOT/tests/run-tests.sh"
printf '%s\n' 'Static and behavioral verification passed.'
