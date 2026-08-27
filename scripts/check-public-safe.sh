#!/bin/sh
set -eu

# Scans everything the allowlist would publish for material that must not leave
# the private repository.
#
# The allowlist decides which files go out. This decides whether what is inside
# them may. Both are needed and neither substitutes for the other: real
# subscriber identifiers reached the public repository inside files that were
# entirely legitimate to publish -- test fixtures -- and no path rule would
# have stopped them.
#
# Exit 0 means the publishable set is clean. Any finding is a refusal.

# The tree to scan. Overridable so the guard's own tests can point it at a
# fixture: a scan that has never been shown to catch anything is not evidence
# that there is nothing to catch.
ROOT="${APN_PUBLIC_SCAN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
ALLOWLIST="$ROOT/scripts/public-allowlist.txt"
# Host-specific strings -- network names, addresses, hostnames. It lives only
# in the private repository and is deliberately outside the allowlist, because
# a file listing what must not be published would be the worst thing to
# publish. Absent is a legitimate configuration; the generic rules still run.
PRIVATE_PATTERNS="${APN_PRIVATE_PATTERNS:-$ROOT/scripts/private-scan-patterns.txt}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apn-public-scan.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
FILES="$WORK/files"

findings=0

report() {
	printf 'PUBLIC-UNSAFE: %s\n' "$*" >&2
	findings=$((findings + 1))
}

publishable_files() {
	# Every tracked file the allowlist covers.
	( cd "$ROOT" && git ls-files ) | while IFS= read -r file; do
		while IFS= read -r prefix; do
			case "$prefix" in ''|\#*) continue ;; esac
			case "$prefix" in
				*/)
					case "$file" in "$prefix"*) printf '%s\n' "$file"; break ;; esac
				;;
				*)
					if [ "$file" = "$prefix" ]; then
						printf '%s\n' "$file"
						break
					fi
				;;
			esac
		done <"$ALLOWLIST"
	done
	return 0
}

publishable_files >"$FILES"
[ -s "$FILES" ] || { printf 'The allowlist publishes nothing at all.\n' >&2; exit 1; }

# ---- the scan must have actually read what it cleared ----
#
# A file that is present but reads back as nothing would pass every rule below
# without a single byte being examined, and the scan would call the set clean.
# That is not hypothetical: this repository lives under a folder macOS may
# evict to iCloud, and an evicted file keeps its size in `stat` while returning
# zero bytes to a reader that cannot fault it back in. `brctl download` on the
# tree fixes it; a scan that cannot tell the difference does not get to say the
# set is safe.
while IFS= read -r file; do
	[ -n "$file" ] || continue
	full="$ROOT/$file"
	[ -f "$full" ] || continue
	expected=$(wc -c <"$full" | tr -d ' ')
	[ "$expected" -gt 0 ] || continue
	actual=$(cat "$full" | wc -c | tr -d ' ')
	[ "$actual" = "$expected" ] && continue
	printf 'PUBLIC-UNSAFE: %s could not be read (%s bytes on disk, %s read); ' \
		"$file" "$expected" "$actual" >&2
	printf 'the scan cannot clear a file it has not seen\n' >&2
	exit 1
done <"$FILES" || exit 1

# ---- identifiers ----
#
# A subscriber or equipment identifier is a long run of digits. Rather than
# trying to recognise a real one -- which is the judgement call that failed
# before -- anything of the right shape is a finding unless it is obviously
# synthetic. "Obviously synthetic" means a run of at least six zeros, or the
# same digit repeated: a real IMEI, ICCID, IMSI or EID essentially never looks
# like that, and a fixture can always be written so that it does.
# One file is exempt from this rule and from this rule only. The generated
# provider database matches subscribers by IMSI prefix, so operator matching
# rules of identifier length are its entire content -- and that content comes
# from AOSP and GNOME MBPI, declared in its own header, rather than from
# anything typed here. Every other rule below still applies to it, which is the
# point of exempting a rule instead of a file: an exemption is exactly where a
# leak would otherwise hide.
identifier_shape_exempt() {
	case "$1" in
		# Releases before 0.8.0 carried the same generated public database in
		# the core package, before it became independently versioned.
		files/usr/share/apn-autoconfig/providers.tsv) return 0 ;;
		apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv) return 0 ;;
	esac
	return 1
}

while IFS= read -r file; do
	[ -f "$ROOT/$file" ] || continue
	case "$file" in
		*.png|*.jpg|*.jpeg|*.gif|*.webp|*.gz|*.xz|*.zst|*.zip|*.apk|*.adb)
			report "$file is a binary or archive the source scanner cannot clear"
			continue
		;;
	esac
	identifier_shape_exempt "$file" && continue
	suspicious="$(grep -ohE '\b[0-9]{14,20}\b|\b[0-9]{32}\b' "$ROOT/$file" 2>/dev/null |
		grep -vE '0{6}' | grep -vE '^([0-9])\1+$' | sort -u || :)"
	for value in $suspicious; do
		# Never echo the value. A refusal log is not another place to copy a
		# subscriber identifier into.
		report "$file carries an identifier-shaped value that does not look synthetic"
	done
done <"$FILES"

# ---- addresses of the maintainer's own network ----
while IFS= read -r file; do
	[ -f "$ROOT/$file" ] || continue
	hits="$(grep -ohE '\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\b' \
		"$ROOT/$file" 2>/dev/null | sort -u || :)"
	for value in $hits; do
		report "$file carries a private network address"
	done
done <"$FILES"

# ---- key material ----
# Split the signatures in this source file so the scanner can itself be part
# of the public provider pipeline without mistaking its rules for a key.
key_pattern='BEGIN [A-Z ]*PRIVATE'" KEY"'|ssh-rsa '"AAAA"'|ssh-ed25519 '"AAAA"
while IFS= read -r file; do
	[ -f "$ROOT/$file" ] || continue
	if grep -qE "$key_pattern" "$ROOT/$file" 2>/dev/null; then
		report "$file carries key material"
	fi
done <"$FILES"

# ---- whatever else this router's owner has named ----
if [ -r "$PRIVATE_PATTERNS" ]; then
	while IFS= read -r pattern; do
		case "$pattern" in ''|\#*) continue ;; esac
		while IFS= read -r file; do
			[ -f "$ROOT/$file" ] || continue
			if grep -qF "$pattern" "$ROOT/$file" 2>/dev/null; then
				# The pattern itself is not printed: this message is allowed to
				# travel further than the file it is about.
				report "$file matches a private pattern"
			fi
		done <"$FILES"
	done <"$PRIVATE_PATTERNS"
fi

if [ "$findings" -ne 0 ]; then
	printf '%s finding(s); nothing is published.\n' "$findings" >&2
	exit 1
fi
printf 'Publishable set is clean (%s files).\n' "$(wc -l <"$FILES" | tr -d ' ')"
