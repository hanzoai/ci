#!/usr/bin/env bash
# Tests for bin/conflictmarkers. Offline and deterministic: every case is a git
# repo written into a temp dir. Run: bash bin/conflictmarkers_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
CM="$PWD/bin/conflictmarkers"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# The markers are built rather than written, so this file is not itself a case.
L=$(printf '<%.0s' $(seq 7))
E=$(printf '=%.0s' $(seq 7))
R=$(printf '>%.0s' $(seq 7))

# t <name> <want-rc> <filename> <content>
t() {
  local name=$1 want=$2 file=$3 body=$4
  local d="$tmp/$RANDOM$RANDOM"; mkdir -p "$d"
  printf '%s' "$body" > "$d/$file"
  ( cd "$d" && git init -q . \
    && git -c user.email=t@t -c user.name=t add -A \
    && git -c user.email=t@t -c user.name=t commit -qm x ) >/dev/null 2>&1
  out=$( cd "$d" && bash "$CM" . 2>&1 ); rc=$?
  if [ "$rc" = "$want" ]; then printf 'ok    %-56s rc=%s\n' "$name" "$rc"
  else printf 'FAIL  %-56s rc=%s (want %s)\n      %s\n' "$name" "$rc" "$want" "$out"; fail=1; fi
}

echo "--- refused: a merge that shipped both sides ---"
# The live case this exists for: hanzoai/base carried it in a generated .d.ts
# nothing imports, so no compiler ever read it.
t "generated .d.ts" 1 types.d.ts \
  "$(printf 'declare const a: string;\n%s HEAD\nx\n%s\ny\n%s upstream/master\n' "$L" "$E" "$R")"
t "markdown, outside any fence" 1 NOTES.md \
  "$(printf 'intro\n\n%s HEAD\nours\n%s\ntheirs\n%s upstream/master\n' "$L" "$E" "$R")"
t "a real conflict beside a fenced sample" 1 M.md \
  "$(printf '```\n%s ORIGINAL\n%s\n%s UPDATED\n```\n\n%s HEAD\nreal\n%s\nreal2\n%s upstream\n' \
     "$L" "$E" "$R" "$L" "$E" "$R")"

echo "--- allowed: the shape is quoted, not committed ---"
# hanzoai/code documents Void's Search/Replace format, which spells itself the
# way git does. Inside a fence, indenting to escape would change what the page
# SHOWS, so the fence is read instead.
t "fenced search/replace sample (hanzoai/code)" 0 GUIDE.md \
  "$(printf 'Void prompts the model like this:\n\n```\n%s ORIGINAL\n// old\n%s\n// new\n%s UPDATED\n```\n\nDone.\n' \
     "$L" "$E" "$R")"
t "tilde fence" 0 GUIDE.md \
  "$(printf '~~~\n%s ORIGINAL\n%s\n%s UPDATED\n~~~\n' "$L" "$E" "$R")"
# hanzoai/app's builder fixture. Both markers on ONE line is a thing git never
# writes.
t "same-line fixture (hanzoai/app)" 0 t.html \
  "$(printf '%s START_TITLE index.html %s END_TITLE\n' "$L" "$R")"
t "eight angle brackets are a heredoc, not a marker" 0 s.cpp \
  "$(printf '%s< HEAD\nx\n%s\ny\n%s< master\n' "$L" "$E" "$R")"
t "a clean repo" 0 README.md "$(printf 'nothing to see\n')"

exit $fail
