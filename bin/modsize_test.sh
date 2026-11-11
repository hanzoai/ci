#!/usr/bin/env bash
# modsize_test.sh — Go module 500 MiB ceiling gate: allowances, refusals, and
# nested module isolation pinned offline.
#
# bin/modsize runs on every checkout in the build lane and refuses a Go module
# whose tracked regular files reach MODSIZE_MAX_PCT (default 80%) of Go's
# 500 MiB MaxZipFile ceiling. A false negative lets an unfetchable module ship;
# a false positive blocks a multi-module repo whose children carry their own
# go.mod files. This suite pins both directions offline using temp git repos.
set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modsize
pass=0; fail=0

newrepo() {
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  printf 'module example.com/root\n\ngo 1.22\n' > "$d/go.mod"
  printf 'package root\n' > "$d/root.go"
  git -C "$d" add -A
  git -C "$d" commit -qm "initial"
  echo "$d"
}

write_six_mib() {
  dd if=/dev/zero of="$1" bs=1048576 count=6 status=none
}

check() { # name expected_rc pattern dir [pct]
  local name=$1 want=$2 pat=$3 dir=$4 pct=${5:-80}
  local out got
  out=$(MODSIZE_MAX_PCT="$pct" "$BIN" "$dir" 2>&1); got=$?
  if [ "$got" = "$want" ] && { [ -z "$pat" ] || printf '%s\n' "$out" | grep -qF "$pat"; }; then
    pass=$((pass+1)); echo "  ok    $name"
  else
    fail=$((fail+1)); echo "  FAIL  $name (want rc=$want pat='$pat', got rc=$got out='$out')"
  fi
}

echo "BOUNDARIES — non-repo directory and missing directory"

tmp_nonrepo=$(mktemp -d)
check "directory outside any git repo exits 0" 0 "" "$tmp_nonrepo"
rm -rf "$tmp_nonrepo"

check "missing directory exits 1" 1 "modsize: no such directory:" "/tmp/nonexistent-modsize-dir-$$"

echo
echo "SINGLE MODULE — small module passes, over-threshold module fails"

d=$(newrepo)
check "small module prints modsize: OK and exits 0" 0 "modsize: OK" "$d"
write_six_mib "$d/large.bin"
git -C "$d" add -A && git -C "$d" commit -qm "add 6 MiB tracked blob"
check "MODSIZE_MAX_PCT=1 with 6 MiB tracked file exits 1 and names go.mod" 1 "::error file=go.mod::" "$d" 1
rm -rf "$d"

echo
echo "NESTED MODULES — child module bytes are excluded from parent module"

d=$(newrepo)
mkdir -p "$d/sub"
printf 'module example.com/root/sub\n\ngo 1.22\n' > "$d/sub/go.mod"
write_six_mib "$d/sub/heavy.bin"
git -C "$d" add -A && git -C "$d" commit -qm "nested module carries 6 MiB"
out_nested=$(MODSIZE_MAX_PCT=1 "$BIN" "$d" 2>&1); rc_nested=$?
if [ "$rc_nested" = "1" ] \
   && printf '%s\n' "$out_nested" | grep -qF "modsize: OK — ./" \
   && printf '%s\n' "$out_nested" | grep -qF "::error file=sub/go.mod::"; then
  pass=$((pass+1)); echo "  ok    parent passes while nested module fails on its own bytes"
else
  fail=$((fail+1)); echo "  FAIL  parent passes while nested module fails (rc=$rc_nested out='$out_nested')"
fi
rm -rf "$d"

d=$(newrepo)
write_six_mib "$d/root_heavy.bin"
mkdir -p "$d/sub"
printf 'module example.com/root/sub\n\ngo 1.22\n' > "$d/sub/go.mod"
printf 'package sub\n' > "$d/sub/sub.go"
git -C "$d" add -A && git -C "$d" commit -qm "parent module carries 6 MiB, nested module is small"
out_parent=$(MODSIZE_MAX_PCT=1 "$BIN" "$d" 2>&1); rc_parent=$?
if [ "$rc_parent" = "1" ] \
   && printf '%s\n' "$out_parent" | grep -qF "::error file=go.mod::" \
   && printf '%s\n' "$out_parent" | grep -qF "modsize: OK — sub/"; then
  pass=$((pass+1)); echo "  ok    parent fails on its own bytes while small nested module passes"
else
  fail=$((fail+1)); echo "  FAIL  parent fails while nested passes (rc=$rc_parent out='$out_parent')"
fi
rm -rf "$d"

echo
echo "modsize_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
