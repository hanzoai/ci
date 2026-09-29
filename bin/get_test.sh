#!/usr/bin/env bash
# Tests for `get`, which fetches this repository's tools at the ref a caller
# pinned. There is no bin/get: the function lives in the tools step of
# .github/workflows/build.yml, and this suite lifts it out and runs that text.
#
# A caller may pin a branch, a tag or a commit. A commit cannot be a --branch,
# so every sha arrives by fetch: the caller's pin as well as this file's own
# commit, which github.com leaves empty.
#
# Offline: a local repository served over file://. Run: bash bin/get_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
DEF=.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

sed -n '/^          # get BEGIN$/,/^          # get END$/p' "$DEF" | sed 's/^          //' > "$tmp/get.sh"
grep -q '^get() {' "$tmp/get.sh" || {
  echo "FAIL  could not lift get() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }

# The source: two commits on main, a tag on the first. github.com serves a
# reachable commit by sha, so this one does too.
src="$tmp/src"
git init -q -b main "$src"
git -C "$src" config uploadpack.allowReachableSHA1InWant true
g() { git -C "$src" -c user.name=t -c user.email=t@t "$@"; }
echo one > "$src/f"; g add f; g commit -qm one; g tag v9.9.9
old=$(g rev-parse HEAD)
echo two > "$src/f"; g commit -qam two
new=$(g rev-parse HEAD)

# check <name> <want> <JOB_SHA> <expected content of f | fails>
check() {
  local name=$1 want=$2 job=$3 expect=$4 rc got
  rm -rf "$tmp/run"; mkdir -p "$tmp/run"
  RUNNER_TEMP="$tmp/run" JOB_SHA="$job" bash -c '. "$1"; hdr=(); get "$2" "$3"' _ "$tmp/get.sh" "file://$src" "$want" >"$tmp/out" 2>&1; rc=$?
  if [ "$expect" = fails ]; then
    if [ "$rc" != 0 ]; then echo "ok   $name"; else echo "FAIL $name: want a failure, got rc=0"; fail=1; fi
    return
  fi
  got=$(cat "$tmp/run/ci/f" 2>/dev/null || true)
  if [ "$rc" = 0 ] && [ "$got" = "$expect" ]; then echo "ok   $name"; else
    echo "FAIL $name: want f=[$expect], got rc=$rc f=[$got]: $(cat "$tmp/out")"; fail=1; fi
}

check "a branch clones its tip"                      main      ""     two
check "a tag clones the tagged commit"               v9.9.9    ""     one
check "the caller's pinned sha fetches that commit"  "$old"    ""     one
check "this file's own sha fetches that commit"      "$new"    "$new" two
check "a sha the host does not carry fails"          "$(printf '%040d' 7)" "" fails
check "a ref the host does not carry fails"          v0.0.0    ""     fails

exit $fail
