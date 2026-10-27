#!/usr/bin/env bash
# modsize_test.sh — asserts the threshold, report, and refusal behavior
# of bin/modsize against clean, over-ceiling, and nested Go modules.
#
# Offline and deterministic: temp repos, no network.
set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modsize
pass=0; fail=0

newrepo() {
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  printf 'module test\n\ngo 1.27\n' > "$d/go.mod"
  printf 'package main\n' > "$d/main.go"
  git -C "$d" add -A
  git -C "$d" commit -qm "initial"
  echo "$d"
}

check_rc() { # name expected_rc dir [extra_env]
  local name=$1 want=$2 dir=$3 env_var=${4:-}
  local got=0
  if [ -n "$env_var" ]; then
    env "$env_var" "$BIN" "$dir" >/dev/null 2>&1 || got=$?
  else
    "$BIN" "$dir" >/dev/null 2>&1 || got=$?
  fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want rc=$want, got rc=$got)"; fi
}

echo "EMPTY / NON-REPO / MISSING DIRECTORIES"

d_empty=$(mktemp -d)
check_rc "directory outside any git repo exits 0" 0 "$d_empty"
check_rc "missing directory exits 1" 1 "$d_empty/does-not-exist"
rm -rf "$d_empty"

echo
echo "SMALL MODULE"

d=$(newrepo)
out=$("$BIN" "$d" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "modsize: OK"; then
  pass=$((pass+1)); echo "  ok    small module prints modsize: OK and exits 0"
else
  fail=$((fail+1)); echo "  FAIL  small module (got rc=$rc, out=$out)"
fi

echo
echo "OVER CEILING THRESHOLD"

dd if=/dev/zero of="$d/big.bin" bs=1048576 count=6 2>/dev/null
git -C "$d" add big.bin && git -C "$d" commit -qm "add 6MB blob"

out=$(MODSIZE_MAX_PCT=1 "$BIN" "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "::error file=go.mod"; then
  pass=$((pass+1)); echo "  ok    MODSIZE_MAX_PCT=1 with ~6 MiB file exits 1 and prints ::error file=go.mod"
else
  fail=$((fail+1)); echo "  FAIL  MODSIZE_MAX_PCT=1 (got rc=$rc, out=$out)"
fi
rm -rf "$d"

echo
echo "NESTED MODULES (ISOLATION OF BYTE TOTALS)"

# Case 1: Parent is clean (passes), nested module carries 6MB (fails)
d_nested1=$(mktemp -d)
git -C "$d_nested1" init -q
git -C "$d_nested1" config user.email dev@hanzo.ai
git -C "$d_nested1" config user.name "Hanzo Dev"
printf 'module parent\n\ngo 1.27\n' > "$d_nested1/go.mod"
printf 'package parent\n' > "$d_nested1/main.go"
mkdir -p "$d_nested1/sub"
printf 'module sub\n\ngo 1.27\n' > "$d_nested1/sub/go.mod"
dd if=/dev/zero of="$d_nested1/sub/big.bin" bs=1048576 count=6 2>/dev/null
git -C "$d_nested1" add -A && git -C "$d_nested1" commit -qm "add sub module with 6MB blob"

out=$(MODSIZE_MAX_PCT=1 "$BIN" "$d_nested1" 2>&1) || rc=$?
if echo "$out" | grep -q "modsize: OK — ./" && echo "$out" | grep -q "::error file=sub/go.mod"; then
  pass=$((pass+1)); echo "  ok    nested isolation: parent passes, nested fails (parent not charged sub's bytes)"
else
  fail=$((fail+1)); echo "  FAIL  nested isolation case 1 (out=$out)"
fi
rm -rf "$d_nested1"

# Case 2: Parent carries 6MB (fails), nested module is clean (passes)
d_nested2=$(mktemp -d)
git -C "$d_nested2" init -q
git -C "$d_nested2" config user.email dev@hanzo.ai
git -C "$d_nested2" config user.name "Hanzo Dev"
printf 'module parent\n\ngo 1.27\n' > "$d_nested2/go.mod"
dd if=/dev/zero of="$d_nested2/big.bin" bs=1048576 count=6 2>/dev/null
mkdir -p "$d_nested2/sub"
printf 'module sub\n\ngo 1.27\n' > "$d_nested2/sub/go.mod"
printf 'package sub\n' > "$d_nested2/sub/sub.go"
git -C "$d_nested2" add -A && git -C "$d_nested2" commit -qm "add parent big blob and clean sub module"

out=$(MODSIZE_MAX_PCT=1 "$BIN" "$d_nested2" 2>&1) || rc=$?
if echo "$out" | grep -q "::error file=go.mod" && echo "$out" | grep -q "modsize: OK — sub/"; then
  pass=$((pass+1)); echo "  ok    nested isolation: parent fails, nested passes (sub not charged parent's bytes)"
else
  fail=$((fail+1)); echo "  FAIL  nested isolation case 2 (out=$out)"
fi
rm -rf "$d_nested2"

echo
echo "modsize_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
