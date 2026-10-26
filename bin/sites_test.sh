#!/usr/bin/env bash
# Tests for bin/sites: which exports a ref publishes, read once for the test job
# (which carries a gate-built export) and the publish job (which ships it).
# Run: bash bin/sites_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin/sites"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s (got: %s)\n' "$1" "$(tr '\n' ' ' < "$T/out")"; fail=1; }
run() { # run <event> <ref> <reftype> <cmd>
  HANZO_YML="$T/hanzo.yml" GITHUB_EVENT_NAME=$1 GITHUB_REF_NAME=$2 GITHUB_REF_TYPE=$3 bash "$BIN" "$4" > "$T/out" 2>&1
}

printf 'test: []\n' > "$T/hanzo.yml"
run push main branch pairs; [ $? = 0 ] && [ ! -s "$T/out" ] && ok "no site: publishes nothing" || no "no site: publishes nothing"

printf 'site:\n  slug: hanzo-blog\n  dir: out\n' > "$T/hanzo.yml"
run push main branch pairs; [ ! -s "$T/out" ] && ok "a branch on: does not name publishes nothing" || no "a branch on: does not name publishes nothing"
run push v0.1.2 tag pairs; [ "$(cat "$T/out")" = "hanzo-blog=out" ] && ok "a tag publishes" || no "a tag publishes"
run push main branch build; [ -z "$(cat "$T/out")" ] && ok "no build: named is an empty build" || no "no build: named is an empty build"

printf 'site:\n  slug: ui\n  dir: dist\n  on: [main]\n  build: pnpm build\n' > "$T/hanzo.yml"
run push main branch pairs; [ "$(cat "$T/out")" = "ui=dist" ] && ok "a branch on: names publishes" || no "a branch on: names publishes"
run pull_request main branch pairs; [ ! -s "$T/out" ] && ok "a pull request publishes nothing" || no "a pull request publishes nothing"
run push main branch build; [ "$(cat "$T/out")" = "pnpm build" ] && ok "site.build is the build" || no "site.build is the build"

printf 'site-build: make all\nsites:\n  - {slug: a, dir: out/a, on: [main]}\n  - {slug: b, dir: out/b}\n' > "$T/hanzo.yml"
run push main branch pairs; [ "$(tr '\n' ' ' < "$T/out")" = "a=out/a b=out/b " ] && ok "sites: publishes every brand on the first entry's gate" || no "sites: publishes every brand on the first entry's gate"
run push main branch build; [ "$(cat "$T/out")" = "make all" ] && ok "site-build is the build for sites:" || no "site-build is the build for sites:"

printf 'site:\n  slug: a\n  dir: out\nsites:\n  - {slug: b, dir: out}\n' > "$T/hanzo.yml"
run push v1 tag pairs; [ $? = 1 ] && grep -q 'BOTH site: and sites:' "$T/out" && ok "both spellings are refused" || no "both spellings are refused"

printf 'site:\n  slug: a\n' > "$T/hanzo.yml"
run push v1 tag pairs; [ $? = 1 ] && grep -q 'both slug: .* and dir:' "$T/out" && ok "a site without its dir is refused" || no "a site without its dir is refused"

mkdir -p "$T/e/a" && printf 'x' > "$T/e/a/1" && printf 'y' > "$T/e/2"
one=$(bash "$BIN" digest "$T/e"); cp -a "$T/e" "$T/f"
[ "$(bash "$BIN" digest "$T/f")" = "$one" ] && ok "an export's digest is its paths and bytes, wherever it sits" || no "an export's digest is its paths and bytes, wherever it sits"
printf 'z' > "$T/f/2"
[ "$(bash "$BIN" digest "$T/f")" != "$one" ] && ok "a byte that moved moves the digest" || no "a byte that moved moves the digest"
mv "$T/f/2" "$T/f/3"; printf 'y' > "$T/f/3"
[ "$(bash "$BIN" digest "$T/f")" != "$one" ] && ok "a file that moved moves the digest" || no "a file that moved moves the digest"

exit $fail
