#!/usr/bin/env bash
# Tests for bin/narrative. Offline and deterministic: every case is a git repo
# written into a temp dir. Run: bash bin/narrative_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
N="$PWD/bin/narrative"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# t <name> <want-rc> <want-in-output> <mode> <message>
t() {
  local name=$1 want=$2 grepfor=$3 mode=$4 msg=$5
  local d="$tmp/$RANDOM$RANDOM"; mkdir -p "$d"
  local g=(git -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null)
  ( cd "$d" && git init -q . && echo base > f && "${g[@]}" add -A \
    && "${g[@]}" commit -qm "Start" && echo next >> f \
    && "${g[@]}" commit -qam "$msg" ) >/dev/null 2>&1
  out=$( cd "$d" && bash "$N" $mode HEAD~1..HEAD 2>&1 ); rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$grepfor" ] || grep -q -- "$grepfor" <<<"$out"; }; then
    printf 'ok    %-64s rc=%s\n' "$name" "$rc"
  else
    printf 'FAIL  %-64s rc=%s (want %s, output to carry %q)\n%s\n' "$name" "$rc" "$want" "$grepfor" "$out"; fail=1
  fi
}

echo "--- a pull request fails on a severity label ---"
t "RED HIGH label"                1 "::error"   --strict "fix RED HIGH cross-tenant read"
t "parenthesised severity"        1 "::error"   --strict "Close the org read (CRITICAL)"
t "severity: field"               1 "::error"   --strict "$(printf 'Scope reads\n\nseverity: high')"
t "a CVE id"                      1 "::error"   --strict "Bump x for CVE-2026-1234"

echo "--- a pull request only warns on a narrative ---"
t "outage account"                0 "::warning" --strict "The gate answered 503 during the outage"
t "bypass account"                0 "::warning" --strict "Close the auth bypass"
t "fails open"                    0 "::warning" --strict "The gate fails open when commerce is down"

echo "--- a push never fails ---"
t "label on a push"               0 "::warning" ""       "fix RED HIGH cross-tenant read"

echo "--- the engineering reason passes clean ---"
t "rotate a key"                  0 "0 with a severity label, 0 narrating" --strict "Rotate the signing key into KMS"
t "scope deletes"                 0 "0 with a severity label, 0 narrating" --strict "Scope identity deletes to the caller's org"
t "high as ordinary english"      0 "0 with a severity label, 0 narrating" --strict "Raise the high-water mark for the queue"
t "tokens as text"                0 "0 with a severity label, 0 narrating" --strict "Count input tokens before the model call"

exit $fail
