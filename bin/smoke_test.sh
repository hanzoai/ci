#!/usr/bin/env bash
# Tests for bin/smoke against a small export on disk.
# Run: bash bin/smoke_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin/smoke"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok() { printf 'ok    %s\n' "$1"; }
no() { printf "FAIL  %s\n" "$1"; sed "s/^/        /" "$T/log"; fail=1; }
mkdir -p "$T/out/_next/static" "$T/out/blog" "$T/out/docs"
echo '<script src="/_next/static/a.js?v=1"></script><link href="/_next/static/a.css" rel=stylesheet><a href="/blog">b</a><img src="//cdn.test/x.png">' > "$T/out/index.html"
: > "$T/out/_next/static/a.js"; : > "$T/out/_next/static/a.css"
echo '<p>blog</p>' > "$T/out/blog/index.html"; echo '<p>flat</p>' > "$T/out/docs.html"
bash "$BIN" "$T/out" /blog /docs > "$T/log" 2>&1 && ok "every route has a page and every page its assets" || no "every route has a page and every page its assets"
rm "$T/out/_next/static/a.css"
bash "$BIN" "$T/out" > "$T/log" 2>&1; [ $? = 1 ] && grep -q 'needs /_next/static/a.css' "$T/log" && ok "a page whose stylesheet is missing fails" || no "a page whose stylesheet is missing fails"
bash "$BIN" "$T/out" /nowhere > "$T/log" 2>&1; [ $? = 1 ] && grep -q '/nowhere has no page' "$T/log" && ok "a route with no page fails" || no "a route with no page fails"
exit $fail
