#!/usr/bin/env bash
# modsize_test.sh — offline, deterministic tests for bin/modsize
set -uo pipefail

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modsize
pass=0; fail=0

newrepo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  echo "$d"
}

check() { # name expected_rc dir [extra_env...]
  local name=$1 want=$2 dir=$3
  shift 3
  local out got
  out=$(env "$@" "$BIN" "$dir" 2>&1)
  got=$?
  if [ "$got" = "$want" ]; then
    pass=$((pass+1))
    echo "  ok    $name"
  else
    fail=$((fail+1))
    echo "  FAIL  $name (want rc=$want, got rc=$got)"
    echo "        output: $out"
  fi
}

echo "=== Testing bin/modsize ==="

# 1. Non-repo directory exits 0
d_nonrepo=$(mktemp -d)
check "directory outside any git repo exits 0" 0 "$d_nonrepo"
rm -rf "$d_nonrepo"

# 2. Missing directory exits 1
check "missing directory exits 1" 1 "/tmp/nonexistent-dir-$RANDOM-$RANDOM"

# 3. Small module exits 0 and prints modsize: OK
d=$(newrepo)
printf 'module example.com/small

go 1.22
' > "$d/go.mod"
printf 'package main

func main() {}
' > "$d/main.go"
git -C "$d" add -A && git -C "$d" commit -qm "initial"
out=$("$BIN" "$d" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "modsize: OK"; then
  pass=$((pass+1))
  echo "  ok    small module prints modsize: OK and exits 0"
else
  fail=$((fail+1))
  echo "  FAIL  small module (rc=$rc, out=$out)"
fi
rm -rf "$d"

# 4. Large module with MODSIZE_MAX_PCT=1 exits 1 and prints ::error file=go.mod
d=$(newrepo)
printf 'module example.com/large

go 1.22
' > "$d/go.mod"
# Generate ~6 MiB file
head -c $((6 * 1024 * 1024)) /dev/zero | tr '\0' 'x' > "$d/bigfile.bin"
git -C "$d" add -A && git -C "$d" commit -qm "add big file"
out=$(MODSIZE_MAX_PCT=1 "$BIN" "$d" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "::error file=go.mod"; then
  pass=$((pass+1))
  echo "  ok    oversized module with MODSIZE_MAX_PCT=1 exits 1 and prints ::error"
else
  fail=$((fail+1))
  echo "  FAIL  oversized module (rc=$rc, out=$out)"
fi
rm -rf "$d"

# 5. Nested module isolation: nested large file not charged to parent
d=$(newrepo)
printf 'module example.com/parent

go 1.22
' > "$d/go.mod"
printf 'package parent
' > "$d/parent.go"
mkdir -p "$d/submod"
printf 'module example.com/parent/submod

go 1.22
' > "$d/submod/go.mod"
head -c $((6 * 1024 * 1024)) /dev/zero | tr '\0' 'x' > "$d/submod/nested.bin"
git -C "$d" add -A && git -C "$d" commit -qm "parent and submod"

# Check parent module alone (pointing at root) with MODSIZE_MAX_PCT=1
# Submod will fail, but parent's own slice has only tiny parent.go
out=$(MODSIZE_MAX_PCT=1 "$BIN" "$d" 2>&1)
rc=$?
if echo "$out" | grep -q "example.com/parent/submod" && echo "$out" | grep -q "::error file=submod/go.mod"; then
  pass=$((pass+1))
  echo "  ok    nested module failure flagged specifically on submod"
else
  fail=$((fail+1))
  echo "  FAIL  nested module isolation (out=$out)"
fi
rm -rf "$d"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
