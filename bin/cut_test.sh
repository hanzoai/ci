#!/usr/bin/env bash
# Tests for the `cut` function that picks the version a regenerated client is
# tagged at and writes it into the file the repo keeps it in. There is no
# bin/cut: the function lives in .github/workflows/build.yml, and this suite
# LIFTS IT OUT and runs it, the way bin/kind_test.sh does, so what is tested is
# the text the runner executes.
#
# The case it exists for: the release hands its number down (spec-version), and
# the tag is cut at that number. The file has to carry it too. It did not: the
# rewrite ran only when the lane derived a patch itself, so a fanout from cloud
# v8.5.189 tagged rust-sdk v8.5.189 over a Cargo.toml still reading 8.5.156.
# The repo's release job refused the mismatch, and the js, python and java
# publishers saw an unchanged version and published nothing.
#
# Offline: a file in a temp dir, a version out. Run: bash bin/cut_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# The runner's sed is GNU sed, and `0,/re/` is GNU-only. A developer on macOS
# runs this with gsed standing in for it.
if ! sed --version >/dev/null 2>&1; then
  command -v gsed >/dev/null 2>&1 || { echo "FAIL  this suite needs GNU sed (gsed on macOS) — the runner's sed"; exit 1; }
  mkdir -p "$tmp/bin"; ln -s "$(command -v gsed)" "$tmp/bin/sed"; PATH="$tmp/bin:$PATH"
fi

sed -n '/^          # cut BEGIN$/,/^          # cut END$/p' "$DEF" | sed 's/^          //' > "$tmp/cut.sh"
grep -q '^cut() {' "$tmp/cut.sh" || {
  echo "FAIL  could not lift cut() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }
# shellcheck disable=SC1090
. "$tmp/cut.sh"

# case <name> <released> <file content> <want NEXT> <want file content | -> [refuses]
check() {
  local name=$1 released=$2 content=$3 want=$4 wantfile=$5 refuses=${6:-} out rc
  printf '%s\n' "$content" > "$tmp/Cargo.toml"
  local read="sed -n 's/^version = \"\\(.*\\)\"/\\1/p' $tmp/Cargo.toml"
  local cur; cur=$(bash -c "$read")
  out=$(cd "$tmp" && cut "$released" "$cur" "$tmp/Cargo.toml" "$read"; rc=$?; echo "rc=$rc NEXT=$NEXT")
  rc=$(sed -n 's/^rc=\([0-9]*\) .*/\1/p' <<<"$out")
  local got; got=$(sed -n 's/^rc=[0-9]* NEXT=//p' <<<"$out")
  if [ -n "$refuses" ]; then
    if [ "$rc" != 0 ] && grep -q '::error::' <<<"$out"; then echo "ok   $name"; else
      echo "FAIL $name: want a refusal, got rc=$rc: $out"; fail=1; fi
    return
  fi
  if [ "$rc" = 0 ] && [ "$got" = "$want" ] && [ "$(cat "$tmp/Cargo.toml")" = "$wantfile" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want NEXT=$want and file [$wantfile], got rc=$rc NEXT=$got and file [$(cat "$tmp/Cargo.toml")]"; fail=1
  fi
}

check "the release's number is written where the version lives" \
  8.5.189 'version = "8.5.156"' 8.5.189 'version = "8.5.189"'
check "a derived patch is written too" \
  "" 'version = "8.5.156"' 8.5.157 'version = "8.5.157"'
check "a release at the number already there rewrites nothing" \
  8.5.156 'version = "8.5.156"' 8.5.156 'version = "8.5.156"'
check "only the first occurrence moves" \
  8.5.189 $'version = "8.5.156"\ndep = "8.5.156"' 8.5.189 $'version = "8.5.189"\ndep = "8.5.156"'
check "a file with no version to rewrite refuses" \
  8.5.189 'name = "x"' "" "" refuses
check "a version that is not x.y.z refuses a derived patch" \
  "" 'version = "0.1.0-alpha.5"' "" "" refuses
check "a release's version that is not x.y.z refuses before sed reads it" \
  '8.5.189/;e touch pwned;#' 'version = "8.5.156"' "" "" refuses
[ ! -e "$tmp/pwned" ] || { echo "FAIL a release's version ran a command through sed"; fail=1; }

# No file: the tag is the version (a Go module), so only NEXT moves.
NEXT=unset; cut 8.5.189 8.5.156 "" ""
[ "$NEXT" = 8.5.189 ] && echo "ok   a tag-versioned repo takes the release's number" || {
  echo "FAIL a tag-versioned repo: NEXT=$NEXT"; fail=1; }
NEXT=unset; cut "" "" "" ""
[ -z "$NEXT" ] && echo "ok   nothing declared cuts nothing" || { echo "FAIL nothing declared: NEXT=$NEXT"; fail=1; }

exit $fail
