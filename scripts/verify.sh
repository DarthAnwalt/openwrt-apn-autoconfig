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
sh -n "$ROOT/scripts/verify.sh"

python3 -m json.tool "$ROOT/luci-app-apn-autoconfig/root/usr/share/luci/menu.d/luci-app-apn-autoconfig.json" >/dev/null
python3 -m json.tool "$ROOT/luci-app-apn-autoconfig/root/usr/share/rpcd/acl.d/luci-app-apn-autoconfig.json" >/dev/null
if command -v node >/dev/null 2>&1; then
	node --check "$ROOT/luci-app-apn-autoconfig/htdocs/luci-static/resources/view/network/apn-autoconfig.js"
fi

awk -F '\t' '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
	NF != 8 { print "invalid TSV field count at line " NR > "/dev/stderr"; bad=1 }
	END { exit bad }
' "$ROOT/files/usr/share/apn-autoconfig/providers.tsv"

sh "$ROOT/tests/run-tests.sh"
printf '%s\n' 'Static and behavioral verification passed.'
