#!/usr/bin/env bash
# ignoretracked_test.sh — test suite for bin/ignoretracked
# Follows the pattern of existing bin/*_test.sh suites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh" 2>/dev/null || {
  # Fallback if test-helpers.sh does not exist
  pass=0; fail=0
  ok()   { pass=$((pass+1)); echo "ok - $1"; }
  nok()  { fail=$((fail+1)); echo "not ok - $1"; }
  plan() { echo "1..$1"; }
  done_testing() { echo "# pass=$pass fail=$fail"; [ "$fail" -eq 0 ]; }
}

plan 8

# --- Test 1: directory outside a repo exits 0 ---
tmp=$(mktemp -d)
result=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "non-repo directory exits 0"; else nok "non-repo directory exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 2: repo with nothing tracked exits 0 ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
result=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "empty repo exits 0"; else nok "empty repo exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 3: repo with tracked file not in .gitignore exits 0 ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
echo "hello" > "$tmp/README.md"
git -C "$tmp" add README.md 2>/dev/null
result=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "tracked non-ignored file exits 0"; else nok "tracked non-ignored file exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 4: small tracked file matching .gitignore exits 0 (under threshold) ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
echo "build/" > "$tmp/.gitignore"
mkdir -p "$tmp/build"
echo "small" > "$tmp/build/output.txt"
git -C "$tmp" add -f .gitignore build/output.txt 2>/dev/null
result=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "small ignored tracked file exits 0"; else nok "small ignored tracked file exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 5: large tracked file matching .gitignore exits non-zero ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
echo "bulk/" > "$tmp/.gitignore"
mkdir -p "$tmp/bulk"
dd if=/dev/zero of="$tmp/bulk/big.bin" bs=1024 count=1024 2>/dev/null
git -C "$tmp" add -f .gitignore bulk/big.bin 2>/dev/null
result=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -ne 0 ]; then ok "large ignored tracked file fails"; else nok "large ignored tracked file fails (got $result)"; fi
rm -rf "$tmp"

# --- Test 6: output mentions the offending path on failure ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
echo "bulk/" > "$tmp/.gitignore"
mkdir -p "$tmp/bulk"
dd if=/dev/zero of="$tmp/bulk/big.bin" bs=1024 count=1024 2>/dev/null
git -C "$tmp" add -f .gitignore bulk/big.bin 2>/dev/null
output=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>&1)
if echo "$output" | grep -q "bulk"; then ok "failure output names offending path"; else nok "failure output names offending path"; fi
rm -rf "$tmp"

# --- Test 7: .gitignore with no tracked matches exits 0 ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
echo "node_modules/" > "$tmp/.gitignore"
echo "code" > "$tmp/main.go"
git -C "$tmp" add .gitignore main.go 2>/dev/null
result=$("$SCRIPT_DIR/ignoretracked" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "gitignore with no tracked matches exits 0"; else nok "gitignore with no tracked matches exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 8: missing argument defaults to current directory ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
result=$(cd "$tmp" && "$SCRIPT_DIR/ignoretracked" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "no argument defaults to cwd"; else nok "no argument defaults to cwd (got $result)"; fi
rm -rf "$tmp"

done_testing
