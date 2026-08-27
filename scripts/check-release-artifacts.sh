#!/bin/sh
set -eu

# Refuse a release after it has been built if an APK payload, package metadata
# or signed-feed file carries material that belongs only to the maintainer.
# Source scanning is necessary but insufficient: packaging is allowed to add
# files, and the final artifact is what leaves the private repository.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PRIVATE_PATTERNS="${APN_PRIVATE_PATTERNS:-$ROOT/scripts/private-scan-patterns.txt}"
MODE=apk
APK_TOOL=
TARGET=

case "${1:-}" in
	--tree)
		MODE=tree
		TARGET="${2:-}"
	;;
	*)
		APK_TOOL="${1:-}"
		TARGET="${2:-}"
	;;
esac

fail() { printf 'RELEASE-UNSAFE: %s\n' "$*" >&2; exit 1; }

[ -n "$TARGET" ] && [ -d "$TARGET" ] || fail 'a directory to scan is required'
if [ "$MODE" = apk ]; then
	[ -n "$APK_TOOL" ] && [ -x "$APK_TOOL" ] || fail 'an executable apk v3 tool is required'
fi
command -v strings >/dev/null 2>&1 || fail 'strings is required for artifact inspection'

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apn-release-scan.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
SCAN_ROOT="$WORK/tree"
mkdir -p "$SCAN_ROOT"

if [ "$MODE" = tree ]; then
	cp -R "$TARGET/." "$SCAN_ROOT/"
else
	count=0
	find "$TARGET" -type f -name '*.apk' -print | while IFS= read -r package; do
		name="${package##*/}"
		destination="$SCAN_ROOT/apk-$count-$name"
		mkdir -p "$destination"
		"$APK_TOOL" adbdump --format json "$package" >"$destination/metadata.json"
		( cd "$destination" && "$APK_TOOL" extract --allow-untrusted "$package" >/dev/null )
		count=$((count + 1))
	done
	# The shell above is a pipeline subshell, so determine success from the tree.
	find "$SCAN_ROOT" -mindepth 1 -print -quit | grep -q . || fail 'no APK was found to inspect'
	# Scan the index, installer, checksums and other non-APK feed files too.
	find "$TARGET" -type f ! -name '*.apk' -exec cp {} "$SCAN_ROOT/" \;
fi

find "$SCAN_ROOT" -type f -print | while IFS= read -r file; do
	relative="${file#"$SCAN_ROOT"/}"
	text="$WORK/strings"
	strings -a "$file" >"$text" 2>/dev/null || :

	key_pattern='BEGIN [A-Z ]*PRIVATE'" KEY"'|ssh-rsa '"AAAA"'|ssh-ed25519 '"AAAA"
	if grep -qE "$key_pattern" "$text"; then
		fail "$relative carries key material"
	fi
	if grep -qE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' "$text"; then
		fail "$relative carries a private network address"
	fi

	case "$relative" in
		usr/share/apn-autoconfig/providers.tsv|*/usr/share/apn-autoconfig/providers.tsv) : ;;
		*)
			if grep -ohE '\b[0-9]{14,20}\b|\b[0-9]{32}\b' "$text" 2>/dev/null |
				grep -vE '0{6}' | grep -vE '^([0-9])\1+$' | grep -q .; then
				fail "$relative carries an identifier-shaped value"
			fi
		;;
	esac

	if [ -r "$PRIVATE_PATTERNS" ]; then
		while IFS= read -r pattern; do
			case "$pattern" in ''|\#*) continue ;; esac
			if grep -qF "$pattern" "$text"; then
				fail "$relative matches a private pattern"
			fi
		done <"$PRIVATE_PATTERNS"
	fi
	:
done

printf 'Release artifact set is clean (%s files inspected).\n' \
	"$(find "$SCAN_ROOT" -type f | wc -l | tr -d ' ')"
