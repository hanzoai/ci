#!/usr/bin/env bash
# Tests for bin/jscache: what it carries and under which names, against a stub
# bin/cache that records each call and answers the hit it is told to. The store
# itself is bin/cache's, tested in bin/cache_test.sh.
# Run: bash bin/jscache_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/stub" "$T/repo"
cp bin/jscache "$T/bin/jscache"
cat > "$T/bin/cache" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
[ "$1" = restore ] && echo "hit=${HIT:-miss}" >> "${GITHUB_OUTPUT:-/dev/null}"
exit 0
STUB
printf '#!/bin/sh\necho v22.23.3\n' > "$T/stub/node"
chmod +x "$T/bin/"* "$T/stub/node"
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; sed 's/^/        /' "$CALLS"; fail=1; }
cd "$T/repo" && git init -q && printf 'lockfileVersion: 9\n' > pnpm-lock.yaml \
  && printf '{"name":"x","dependencies":{"next":"15"}}' > package.json && git add -A && git -c user.email=t@t -c user.name=t commit -qm x
export PATH="$T/stub:$PATH" RUNNER_TEMP="$T" GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 CALLS="$T/calls"
arch=$(uname -m)

: > "$CALLS"; bash "$T/bin/jscache" restore > /dev/null 2>&1
grep -q "^restore node-v22.23.3-$arch [0-9a-f]\{32\} modules=node_modules$" "$CALLS" \
  && grep -q "^restore next-v22.23.3-$arch $GITHUB_SHA n_root=.next/cache$" "$CALLS" \
  && ok "restore asks for node_modules by lockfile and Next's cache by commit" || no "restore asks for node_modules by lockfile and Next's cache by commit"

mkdir -p node_modules/a .next/cache/fetch-cache .next/cache/webpack
: > "$CALLS"; bash "$T/bin/jscache" save > /dev/null 2>&1
grep -q "^save node-v22.23.3-$arch .* modules=node_modules$" "$CALLS" && grep -q "^save next-v22.23.3-$arch $GITHUB_SHA n_root=.next/cache$" "$CALLS" \
  && [ ! -e .next/cache/fetch-cache ] && [ -d .next/cache/webpack ] \
  && ok "save writes both after a miss, without the fetch cache" || no "save writes both after a miss, without the fetch cache"

: > "$CALLS"; HIT=exact bash "$T/bin/jscache" restore > /dev/null 2>&1; : > "$CALLS"; bash "$T/bin/jscache" save > /dev/null 2>&1
! grep -q "^save node-" "$CALLS" && grep -q "^save next-" "$CALLS" \
  && ok "an exact node_modules hit is not saved again; Next's cache still is" || no "an exact node_modules hit is not saved again; Next's cache still is"

mkdir -p apps/docs && printf '{"name":"docs","dependencies":{"next":"16"}}' > apps/docs/package.json
: > "$CALLS"; bash "$T/bin/jscache" restore > /dev/null 2>&1
grep -q "^restore next-v22.23.3-$arch $GITHUB_SHA n_root=.next/cache n_apps_docs=apps/docs/.next/cache$" "$CALLS" \
  && ok "every package that depends on next carries its own .next/cache, by directory" \
  || no "every package that depends on next carries its own .next/cache, by directory"
rm -rf apps

printf '{"name":"x"}' > package.json; git -c user.email=t@t -c user.name=t commit -qam y
: > "$CALLS"; bash "$T/bin/jscache" restore > /dev/null 2>&1
! grep -q "next-" "$CALLS" && ok "a repo without next carries no Next cache" || no "a repo without next carries no Next cache"

cp "$OLDPWD/bin/sites" "$T/bin/sites"; printf 'site:\n  slug: s\n  dir: out\n' > hanzo.yml
: > "$CALLS"; HANZO_CI_ROLE=publish bash "$T/bin/jscache" restore > /dev/null 2>&1
[ ! -s "$CALLS" ] && ok "a publish job that builds no site restores nothing" || no "a publish job that builds no site restores nothing"
printf 'site:\n  slug: s\n  dir: out\n  build: pnpm build\n' > hanzo.yml
: > "$CALLS"; HANZO_CI_ROLE=publish bash "$T/bin/jscache" restore > /dev/null 2>&1
grep -q '^restore node-' "$CALLS" && ok "a publish job that builds its site restores node_modules" || no "a publish job that builds its site restores node_modules"

rm pnpm-lock.yaml; : > "$CALLS"; out=$(bash "$T/bin/jscache" restore 2>&1)
[ ! -s "$CALLS" ] && printf '%s' "$out" | grep -q 'no lockfile' && ok "no root lockfile is a notice" || no "no root lockfile is a notice"
exit $fail
