#!/usr/bin/env bash
# Tests for bin/sites: which exports a ref publishes, and whether a run ships
# nothing else, read once for the gating job and the publish job.
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

printf 'site:\n  slug: a\n  dir: out\ntest: []\n' > "$T/hanzo.yml"
run push main branch alone; [ $? = 0 ] && ok "a run of sites alone ships from its gating job" || no "a run of sites alone ships from its gating job"
for more in 'images: [{name: a}]' 'binaries: [{name: a}]' 'pypi: [py]' 'client: {spec: {repo: a}}' 'bucket: b'; do
  printf 'site:\n  slug: a\n  dir: out\n%s\n' "$more" > "$T/hanzo.yml"
  run push main branch alone; [ $? = 1 ] && ok "a run that also ships ${more%%:*} is not alone" || no "a run that also ships ${more%%:*} is not alone"
done
printf 'images: []\nsites:\n  - {slug: a, dir: out}\n' > "$T/hanzo.yml"
run push main branch alone; [ $? = 0 ] && ok "an empty images: list ships nothing" || no "an empty images: list ships nothing"

exit $fail
