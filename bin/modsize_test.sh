#!/usr/bin/env bash
# modsize_test.sh — pin size refusals, nested module accounting and directory handling.
#
# Offline and deterministic: temp repos, no network.
set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/modsize
pass=0; fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# Keep caller settings from selecting another repository or threshold.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset MODSIZE_MAX_PCT MODSIZE_REF
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# Temporary directories may live inside a checkout; stop discovery at their root.
export GIT_CEILING_DIRECTORIES="$T"

newrepo() {
  local d
  d=$(mktemp -d "$T/repo.XXXXXX")
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  printf 'module example.com/root\n\ngo 1.22\n' > "$d/go.mod"
  git -C "$d" add -A
  git -C "$d" commit -qm "initial"
  echo "$d"
}
blob() { # dir path — six MiB exceeds one percent of the 500 MiB ceiling (~5 MiB)
  dd if=/dev/zero of="$1/$2" bs=1048576 count=6 2>/dev/null
}
check() { # name expected_rc expected_output dir [pct] [ref]
  local name=$1 want=$2 pattern=$3 dir=$4 pct=${5:-80} ref=${6:-HEAD}
  local out got=0
  out=$(MODSIZE_MAX_PCT="$pct" MODSIZE_REF="$ref" bash "$BIN" "$dir" 2>&1) || got=$?
  if [ "$got" = "$want" ] && [[ "$out" == *"$pattern"* ]]; then
    pass=$((pass+1)); echo "  ok    $name"
  else
    fail=$((fail+1)); echo "  FAIL  $name (want rc=$want and '$pattern', got rc=$got)"
    printf '%s\n' "$out"
  fi
}

echo "SIZE LIMIT — tracked bytes and threshold percentage"
d=$(newrepo)
check "small module prints modsize: OK and exits 0" 0 'modsize: OK' "$d"
blob "$d" big.bin
git -C "$d" add -A && git -C "$d" commit -qm "add 6 MiB blob"
check "six MiB fails at MODSIZE_MAX_PCT=1" 1 '::error file=go.mod::' "$d" 1
check "six MiB passes at default threshold" 0 'modsize: OK' "$d"
check "MODSIZE_REF selects an earlier commit" 0 'modsize: OK' "$d" 1 HEAD~1

echo
echo "NESTED MODULES — each module pays only for its own bytes"
d=$(newrepo)
mkdir -p "$d/sub"
printf 'module example.com/sub\n\ngo 1.22\n' > "$d/sub/go.mod"
blob "$d" sub/big.bin
git -C "$d" add -A && git -C "$d" commit -qm "nested module with 6 MiB blob"
check "large nested module fails on sub/go.mod" 1 '::error file=sub/go.mod::' "$d" 1
check "parent module passes when nested module holds the bulk" 1 'modsize: OK — ./' "$d" 1

# Move the bulk to the parent and verify accounting in the reverse direction.
git -C "$d" mv sub/big.bin big.bin
git -C "$d" commit -qm "move 6 MiB blob to parent module"
check "large parent module fails on go.mod" 1 '::error file=go.mod::' "$d" 1
check "nested module passes when parent module holds the bulk" 1 'modsize: OK — sub/' "$d" 1

echo
echo "DIRECTORIES — outside any git repo and missing paths"
mkdir "$T/outside"
check "directory outside any git repo exits 0" 0 '' "$T/outside"
check "missing directory exits 1" 1 'modsize: no such directory:' "$T/missing"

echo
echo "modsize_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
