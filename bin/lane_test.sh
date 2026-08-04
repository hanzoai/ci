#!/usr/bin/env bash
# Tests for bin/lane. Offline and deterministic: the forge is a file:// tree, so
# this needs no network — LANE_FORGE points at fixtures on disk and curl reads
# them. Run: bash bin/lane_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
LANE="$PWD/bin/lane"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# A file:// "forge": v1/repos/<owner>/<name> is a file holding the JSON the real
# endpoint returns. A repo with no file is a 404, which is what curl -f reports.
forge="$tmp/forge"
mk_forge() { mkdir -p "$forge/v1/repos/${1%/*}"; printf '{"full_name":"%s","has_actions":%s,"private":false}' "$1" "$2" > "$forge/v1/repos/$1"; }
mk_forge hanzoai/onforge  true
mk_forge hanzoai/noactions false

# repo <name> <slug> <dirs...> — a checkout with an origin and the given workflow dirs
repo() {
  local d="$tmp/$1"; local slug=$2; shift 2
  mkdir -p "$d"; git -C "$d" init -q 2>/dev/null
  git -C "$d" remote add origin "git@github.com:$slug.git"
  for w in "$@"; do mkdir -p "$d/$w"; printf 'name: x\non: push\n' > "$d/$w/ci.yml"; done
  printf '%s' "$d"
}

# t <name> <want-rc> <dir> [pattern]
t() {
  local name=$1 want=$2 dir=$3 pat=${4:-}
  out=$(LANE_FORGE="file://$forge" GITHUB_REPOSITORY= bash "$LANE" check "$dir" 2>&1); rc=$?
  if [ "$rc" != "$want" ]; then printf 'FAIL  %-52s rc=%s (want %s)\n      %s\n' "$name" "$rc" "$want" "$out"; fail=1; return; fi
  if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q "$pat"; then
    printf 'FAIL  %-52s message missing %s\n      %s\n' "$name" "$pat" "$out"; fail=1; return
  fi
  printf 'ok    %-52s rc=%s\n' "$name" "$rc"
}

# The outage: .hanzo/workflows on a repo the forge has never heard of. github.com
# does not read that directory, so the files are collected by nobody.
t "hanzo-only, absent from forge  -> refuse" 1 "$(repo dead hanzoai/openapi .hanzo/workflows)" "collected by nobody"

# Same placement, but the forge HAS the repo: this is the fleet default and the
# only arrangement in which .hanzo/workflows actually builds.
t "hanzo-only, on forge           -> allow"  0 "$(repo live hanzoai/onforge .hanzo/workflows)" "collects .hanzo/workflows"

# On the forge but actions off: it collects the files and runs none of them. A
# gate that keyed on presence alone would call this healthy.
t "hanzo-only, forge actions off  -> refuse" 1 "$(repo off hanzoai/noactions .hanzo/workflows)" "actions are DISABLED"

# .github/workflows is correct on EITHER host — github reads it, and the forge
# falls through to it — so a repo without .hanzo/workflows is never asked about.
t "github-only, absent from forge -> allow"  0 "$(repo ghonly hanzoai/openapi .github/workflows)"
t "no workflows at all            -> allow"  0 "$(repo bare hanzoai/openapi)"

# Both dirs on a repo the forge does not have: the .hanzo copy is dead weight
# today and is the whole trap tomorrow, the moment the .github copy is deleted.
t "both dirs, absent from forge   -> refuse" 1 "$(repo both hanzoai/openapi .hanzo/workflows .github/workflows)" "collected by nobody"

# $GITHUB_REPOSITORY is what a pipeline knows; it must win over the remote, since
# a runner's checkout may have no origin at all.
d=$(repo envslug hanzoai/openapi .hanzo/workflows)
out=$(LANE_FORGE="file://$forge" GITHUB_REPOSITORY=hanzoai/onforge bash "$LANE" check "$d" 2>&1); rc=$?
if [ "$rc" = 0 ]; then printf 'ok    %-52s rc=0\n' "GITHUB_REPOSITORY overrides origin"
else printf 'FAIL  %-52s rc=%s\n      %s\n' "GITHUB_REPOSITORY overrides origin" "$rc" "$out"; fail=1; fi

# A checkout with no remote and no env cannot be named, and a gate that guesses a
# slug would refuse repos it invented. Say so and pass.
mkdir -p "$tmp/noremote/.hanzo/workflows"; git -C "$tmp/noremote" init -q 2>/dev/null
printf 'name: x\n' > "$tmp/noremote/.hanzo/workflows/ci.yml"
out=$(LANE_FORGE="file://$forge" GITHUB_REPOSITORY= bash "$LANE" check "$tmp/noremote" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "no origin remote"; then printf 'ok    %-52s rc=0\n' "no remote, no env -> say so, do not guess"
else printf 'FAIL  %-52s rc=%s\n      %s\n' "no remote, no env -> say so, do not guess" "$rc" "$out"; fail=1; fi

[ "$fail" = 0 ] && echo "lane_test: all cases pass"
exit "$fail"
