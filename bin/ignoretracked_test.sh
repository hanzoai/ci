#!/usr/bin/env bash
# ignoretracked_test.sh — asserts the threshold, report, and refusal behavior
# of bin/ignoretracked against clean, over-ceiling, and under-ceiling repos.
#
# Offline and deterministic: temp repos, no network.
set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ignoretracked
pass=0; fail=0

newrepo() {
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  printf 'x\n' > "$d/README.md"
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

echo "EMPTY / CLEAN REPOS"

d=$(mktemp -d)
check_rc "directory outside a git repo exits 0" 0 "$d"
rm -rf "$d"

d=$(newrepo)
printf 'target/\n' > "$d/.gitignore"
git -C "$d" add .gitignore && git -C "$d" commit -qm "add gitignore"
out=$("$BIN" "$d" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ignoretracked: OK — nothing tracked that .gitignore ignores"; then
  pass=$((pass+1)); echo "  ok    repo with nothing tracked matching .gitignore prints clean line and exits 0"
else
  fail=$((fail+1)); echo "  FAIL  repo with nothing tracked (got rc=$rc, out=$out)"
fi

echo
echo "TRACKED CONTENT MATCHING .gitignore"

mkdir -p "$d/target"
dd if=/dev/zero of="$d/target/blob.bin" bs=1048576 count=2 2>/dev/null
git -C "$d" add -f target/blob.bin
git -C "$d" commit -qm "force-add ignored 2MB file"

# Over ceiling check: IGNORETRACKED_MAX_MB=1
out=$(IGNORETRACKED_MAX_MB=1 "$BIN" "$d" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && echo "$out" | grep -q "::error::" && echo "$out" | grep -q "over the 1 MB ceiling"; then
  pass=$((pass+1)); echo "  ok    2 MiB tracked-and-ignored with IGNORETRACKED_MAX_MB=1 exits 1 and prints ::error::"
else
  fail=$((fail+1)); echo "  FAIL  2 MiB with max 1MB ceiling (got rc=$rc, out=$out)"
fi

# Under ceiling check: default ceiling (100 MB)
rc=0
out=$("$BIN" "$d" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ignoretracked: OK — 2.0 MB is under the 100 MB ceiling"; then
  pass=$((pass+1)); echo "  ok    2 MiB tracked-and-ignored under default ceiling exits 0 and reports byte count"
else
  fail=$((fail+1)); echo "  FAIL  2 MiB with default ceiling (got rc=$rc, out=$out)"
fi

# By rule report check: names the .gitignore line that matches
if echo "$out" | grep -q "\.gitignore:1:target/"; then
  pass=$((pass+1)); echo "  ok    by rule report identifies .gitignore line (.gitignore:1:target/)"
else
  fail=$((fail+1)); echo "  FAIL  by rule report did not match .gitignore line (out=$out)"
fi

rm -rf "$d"

echo
echo "ignoretracked_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
