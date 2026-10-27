#!/usr/bin/env bash
# Tests for bin/agent: which export each line reaches, and that a line naming
# nothing this publish ships is refused before any export is touched. The tool
# itself is pinned by agent/test (node --test).
# Run: bash bin/agent_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin/agent"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; sed 's/^/        /' "$T/log"; fail=1; }
fresh() { rm -rf "$T/a" "$T/b"; for d in a b; do mkdir -p "$T/$d"; printf '<html><head><title>%s</title></head><body><main><p>%s</p></main></body></html>' "$d" "$d" > "$T/$d/index.html"; done; }
sum() { (cd "$T" && find a b -type f | sort | xargs sha256sum); }

fresh; before=$(sum)
bash "$BIN" "x=$T/a" '' > "$T/log" 2>&1 && [ "$(sum)" = "$before" ] && ok "no line publishes the export as it was built" || no "no line publishes the export as it was built"

fresh
bash "$BIN" "hanzo-x=$T/a" 'a.example.com' > "$T/log" 2>&1 \
  && grep -q '^# a' "$T/a/index.md" && grep -q 'Sitemap: https://a.example.com/sitemap.xml' "$T/a/robots.txt" && [ -f "$T/a/auth.md" ] \
  && ok "one site takes a bare host" || no "one site takes a bare host"

fresh; b=$(cd "$T" && find b -type f | sort | xargs sha256sum)
bash "$BIN" "$(printf 'a=%s@https://a.example.com \nb=%s@https://b.example.com' "$T/a" "$T/b")" '  a=a.example.com --no-robots  ' > "$T/log" 2>&1 \
  && [ -f "$T/a/index.md" ] && [ ! -f "$T/a/robots.txt" ] && [ "$(cd "$T" && find b -type f | sort | xargs sha256sum)" = "$b" ] \
  && ok "of several sites only the one named changes, with its flags" || no "of several sites only the one named changes, with its flags"

for bad in 'c=c.example.com' 'a.example.com'; do
  fresh; before=$(sum)
  bash "$BIN" "$(printf 'a=%s\nb=%s' "$T/a" "$T/b")" "$(printf 'a=a.example.com\n%s' "$bad")" > "$T/log" 2>&1; rc=$?
  [ "$rc" = 1 ] && [ "$(sum)" = "$before" ] && grep -q '::error::agent:' "$T/log" \
    && ok "'$bad' is refused before any export is touched" || no "'$bad' is refused before any export is touched"
done

fresh; rm -rf "$T/b"
bash "$BIN" "b=$T/b" 'b.example.com' > "$T/log" 2>&1; [ $? = 1 ] && grep -q 'the build left no export' "$T/log" \
  && ok "a missing export is refused" || no "a missing export is refused"

fresh
bash "$BIN" "a=$T/a" 'a=A.example.com' > "$T/log" 2>&1; [ $? = 1 ] && grep -q 'not a lowercase hostname' "$T/log" \
  && ok "the tool's own refusal fails the step" || no "the tool's own refusal fails the step"
# CI runs the tools from a symlinked checkout; the tool must run, not exit 0 silent.
fresh; ln -s "$PWD" "$T/link"
bash "$T/link/bin/agent" "a=$T/a" 'a.example.com' > "$T/log" 2>&1 && [ -f "$T/a/index.md" ] && grep -q '^agent a.example.com: ' "$T/log" \
  && ok "a symlinked checkout runs the tool" || no "a symlinked checkout runs the tool"
exit $fail
