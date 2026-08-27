#!/bin/sh
set -eu

# Publishes the signed package repository to the public repository's feed
# branch, from which GitHub Pages serves it.
#
# Why a push rather than a Pages deployment. Development moved to a private
# repository, and Pages for a private repository is a paid feature, so the
# signing has to happen here and the result has to travel to the repository
# that is public. Nothing secret goes with it: what lands there is exactly the
# feed users already download -- packages, the index, its signature, the public
# key and the installer.
#
# The branch is rewritten as a single orphan commit every time rather than
# appended to. That is what the Pages deployment did before, and it keeps a
# published package payload from accumulating in the public repository's
# history release after release. Superseded packages remain available as
# release assets, which is where they were always kept.

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SITE="${FEED_SITE_DIR:-$ROOT/dist/repository}"
REPOSITORY="${PUBLIC_FEED_REPOSITORY:-DarthAnwalt/openwrt-apn-autoconfig}"
BRANCH="${PUBLIC_FEED_BRANCH:-gh-pages}"

fail() { printf 'publish-feed: %s\n' "$*" >&2; exit 1; }

[ -d "$SITE" ] || fail "no signed repository at $SITE; run build-repository.sh first"
[ -f "$SITE/public-key.pem" ] || fail 'the signed repository has no public key in it'
[ -f "$SITE/install.sh" ] || fail 'the signed repository has no installer in it'
[ -n "${PUBLIC_FEED_TOKEN:-}" ] || fail 'PUBLIC_FEED_TOKEN is not set'

# The signing key must never travel with the feed. It is written to a temporary
# file during signing and removed afterwards, but this is the last point at
# which a mistake there would become public, so it is checked rather than
# assumed.
if find "$SITE" -name '*.pem' -type f -exec grep -l 'PRIVATE KEY' {} + 2>/dev/null | grep -q .; then
	fail 'a private key is inside the directory about to be published'
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/apn-autoconfig-feed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# The token reaches git through the credential helper's stdin rather than the
# remote URL, so it is never written into .git/config and cannot be echoed back
# by a git error message that quotes the remote.
cat >"$WORK/askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
	Username*) printf 'x-access-token\n' ;;
	*) printf '%s\n' "$PUBLIC_FEED_TOKEN" ;;
esac
ASKPASS
chmod 0700 "$WORK/askpass"
GIT_ASKPASS="$WORK/askpass"
export GIT_ASKPASS
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

TREE="$WORK/tree"
mkdir -p "$TREE"
cp -R "$SITE/." "$TREE/"
# Pages would otherwise run the content through Jekyll, which drops files and
# directories whose names begin with an underscore.
: >"$TREE/.nojekyll"

git -C "$TREE" init -q -b "$BRANCH"
git -C "$TREE" config user.name 'apn-autoconfig release'
git -C "$TREE" config user.email 'noreply@github.com'
git -C "$TREE" add -A
git -C "$TREE" -c commit.gpgsign=false commit -q \
	-m "Signed package repository from ${FEED_SOURCE_DESCRIPTION:-a verified build}"

printf 'Publishing %s file(s) to %s of %s\n' \
	"$(git -C "$TREE" ls-files | wc -l | tr -d ' ')" "$BRANCH" "$REPOSITORY"

[ "${FEED_DRY_RUN:-0}" = 0 ] || {
	printf 'Dry run: nothing was pushed.\n'
	exit 0
}

git -C "$TREE" push --force --quiet \
	"https://github.com/$REPOSITORY.git" "$BRANCH:$BRANCH"
printf 'Published.\n'
