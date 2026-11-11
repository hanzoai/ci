#!/usr/bin/env bash
# ignoretracked_test.sh — pin the byte ceiling, the clean paths, and the by-rule report.
#
# bin/ignoretracked refuses a checkout only when the total bytes of tracked
# files matched by committed .gitignore rules reach or exceed
# IGNORETRACKED_MAX_MB (default 100 MB). Smaller tails are reported (naming the
# offending .gitignore source:line:pattern via `git check-ignore --no-index -v`)
# while exiting 0 so existing repos stay green until cleaned up.
#
# Offline and deterministic: temp git repos, no network.
set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ignoretracked
pass=0; fail=0

newrepo() {
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  printf 'hello\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -qm "initial"
  echo "$d"
}

assert_case() { # name want_rc want_substr cmd...
  local name=$1 want_rc=$2 want_sub=$3
  shift 3
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s\n' "$out" | grep -qF "$want_sub"; then
    pass=$((pass+1))
    echo "  ok    $name"
  else
    fail=$((fail+1))
    echo "  FAIL  $name (want rc=$want_rc substr=[$want_sub], got rc=$rc out=[$out])"
  fi
}

echo "CLEAN & NON-REPO CASES"

nonrepo=$(mktemp -d)
assert_case "directory outside a git repo exits 0" 0 "" "$BIN" "$nonrepo"
rm -rf "$nonrepo"

d=$(newrepo)
printf 'target/\n*.log\n' > "$d/.gitignore"
git -C "$d" add .gitignore && git -C "$d" commit -qm "add gitignore"
assert_case "repo whose .gitignore matches nothing tracked prints nothing-tracked and exits 0" \
  0 "ignoretracked: OK — nothing tracked that .gitignore ignores" \
  "$BIN" "$d"

echo
echo "THRESHOLD & BY-RULE REPORTING"

mkdir -p "$d/target"
dd if=/dev/zero of="$d/target/blob.bin" bs=1048576 count=2 status=none
git -C "$d" add -f target/blob.bin
git -C "$d" commit -qm "force-track 2 MiB ignored artifact"

assert_case "2 MiB force-tracked ignored file with IGNORETRACKED_MAX_MB=1 exits 1 with ::error::" \
  1 "::error::2.0 MB of tracked content is matched by this repo's own .gitignore — over the 1 MB ceiling." \
  env IGNORETRACKED_MAX_MB=1 "$BIN" "$d"

assert_case "same repo under default 100 MB ceiling exits 0 and prints OK with MB count" \
  0 "ignoretracked: OK — 2.0 MB is under the 100 MB ceiling (reported, not blocking)" \
  "$BIN" "$d"

assert_case "by-rule report names the matching .gitignore line" \
  0 ".gitignore:1:target/" \
  "$BIN" "$d"

rm -rf "$d"

echo
echo "ignoretracked_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
