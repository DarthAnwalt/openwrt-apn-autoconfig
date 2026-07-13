#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

sh -n "$ROOT/files/usr/sbin/apn-autoconfig"
sh -n "$ROOT/tests/run-tests.sh"
sh -n "$ROOT/scripts/build-with-sdk.sh"
sh -n "$ROOT/scripts/verify.sh"

awk -F '\t' '
	/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
	NF != 8 { print "invalid TSV field count at line " NR > "/dev/stderr"; bad=1 }
	END { exit bad }
' "$ROOT/files/usr/share/apn-autoconfig/providers.tsv"

sh "$ROOT/tests/run-tests.sh"
printf '%s\n' 'Static and behavioral verification passed.'
