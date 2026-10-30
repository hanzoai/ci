#!/usr/bin/env bash
# ignoretracked_test.sh — offline, deterministic tests for bin/ignoretracked
set -uo pipefail

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ignoretracked
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

echo "=== Testing bin/ignoretracked ==="

# 1. Non-repo directory exits 0
d_nonrepo=$(mktemp -d)
check "directory outside any git repo exits 0" 0 "$d_nonrepo"
rm -rf "$d_nonrepo"

# 2. Missing directory exits 1
check "missing directory exits 1" 1 "/tmp/nonexistent-ignoretracked-$RANDOM-$RANDOM"

# 3. Clean repo: .gitignore matches nothing tracked
d=$(newrepo)
printf 'target/
*.tmp
' > "$d/.gitignore"
printf 'package main
' > "$d/main.go"
git -C "$d" add -A && git -C "$d" commit -qm "initial"
out=$("$BIN" "$d" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "nothing tracked that .gitignore ignores"; then
  pass=$((pass+1))
  echo "  ok    clean repo prints 'nothing tracked' and exits 0"
else
  fail=$((fail+1))
  echo "  FAIL  clean repo (rc=$rc, out=$out)"
fi
rm -rf "$d"

# 4. Tracked file under ignored path exceeding IGNORETRACKED_MAX_MB
d=$(newrepo)
mkdir -p "$d/build"
printf 'build/
' > "$d/.gitignore"
# Generate ~2 MiB file inside ignored directory
head -c $((2 * 1024 * 1024)) /dev/zero | tr '\0' 'y' > "$d/build/artifact.bin"
git -C "$d" add .gitignore
git -C "$d" add -f "$d/build/artifact.bin"
git -C "$d" commit -qm "track ignored artifact"

# Over limit (MAX_MB=1): exits 1 and prints ::error::
out=$(IGNORETRACKED_MAX_MB=1 "$BIN" "$d" 2>&1)
rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "::error::"; then
  pass=$((pass+1))
  echo "  ok    oversized tracked ignored file with MAX_MB=1 exits 1 and prints ::error::"
else
  fail=$((fail+1))
  echo "  FAIL  oversized tracked file (rc=$rc, out=$out)"
fi

# Under limit (default 100 MB ceiling): exits 0 and prints OK with size
out=$("$BIN" "$d" 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "ignoretracked: OK"; then
  pass=$((pass+1))
  echo "  ok    under ceiling exits 0 and reports byte count"
else
  fail=$((fail+1))
  echo "  FAIL  under ceiling (rc=$rc, out=$out)"
fi

# By rule report names the matching .gitignore line
if echo "$out" | grep -q "build/"; then
  pass=$((pass+1))
  echo "  ok    report names matching .gitignore pattern"
else
  fail=$((fail+1))
  echo "  FAIL  missing rule report (out=$out)"
fi
rm -rf "$d"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
