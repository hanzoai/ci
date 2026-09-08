#!/usr/bin/env bash
# Tests for the `kind` function that decides what a repository IS before
# anything is fetched, built or published. There is no bin/kind: the function
# lives inside the one definition of the pipeline, .github/workflows/build.yml,
# and this suite LIFTS IT OUT and runs it. So there is nothing to keep in step —
# what is tested here is the same text the runner executes, and a rule edited in
# one place cannot drift from a rule tested in another.
#
# It has to be lifted rather than called because a run cannot reach a new file in
# this repo: the tools checkout derives its ref from GITHUB_WORKFLOW_REF, which
# git.hanzo.ai does not set, so $CI_HOME resolves to whatever `v1` names rather
# than to the tag the caller pinned.
#
# TWO HALVES, and they are the two halves of the change.
#
#   ABSENT IS IMAGE — every shape a manifest in the fleet actually takes today
#     resolves to `image` and runs exactly as it ran before. The shapes are not
#     invented: they are the fourteen key-sets measured across all 117 manifests
#     in ~/work/{hanzo,lux,zoo}, each with its count, plus the empty file and the
#     missing file. Nothing in the fleet declares `kind:` at all, so this half is
#     the whole of the fleet and it must stay green to the last row.
#
#   A KIND WITH NO LANE HERE REFUSES — a chart repository can no longer reach
#     `no images: in hanzo.yml — test-only caller, skipping build`, exit 0, and
#     report success having delivered nothing. Weighted toward what must NOT
#     pass, because the defect this closes is a GREEN run: a miss here is
#     invisible, and reintroducing it turns the refusal rows red.
#
# Offline and deterministic: files in, a word or a refusal out, no network.
# Run: bash bin/kind_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# A suite that CANNOT RUN reads as a suite that passed, so say so and stop. The
# pipeline provisions this same yq two steps before the function uses it; a
# developer running the suite by hand needs it on PATH.
command -v yq >/dev/null 2>&1 || {
  echo "FAIL  yq is not on PATH — this suite reads manifests with the same yq the pipeline provisions, and a suite that cannot run must not read as passed"
  exit 1; }

sed -n '/^          # kind BEGIN$/,/^          # kind END$/p' "$DEF" | sed 's/^          //' > "$tmp/kind.sh"
grep -q '^kind() {' "$tmp/kind.sh" || {
  echo "FAIL  could not lift kind() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }
# shellcheck disable=SC1090
. "$tmp/kind.sh"

# The closed set, spelled here so the suite fails when the pipeline's list moves
# without this one. Two spellings of a closed set is the drift a closed set
# exists to prevent.
KINDS='image fn chart compose universe'

run() { printf '%s\n' "$@" > "$tmp/m.yml"; kind "$tmp/m.yml" 2>&1; }

# ok <name> <yaml line...> — resolves to `image`, exit 0, nothing else said
ok() {
  local name=$1; shift
  local got rc; got=$(run "$@"); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = image ]; then printf 'ok    %-56s image\n' "$name"
  else printf 'FAIL  %-56s rc=%s out=%s\n' "$name" "$rc" "$got"; fail=1; fi
}

# no <name> <want-in-message> <yaml line...> — refuses, exit 1, message says <want>
no() {
  local name=$1 want=$2; shift 2
  local got rc; got=$(run "$@"); rc=$?
  if [ "$rc" != 0 ] && [ "${got#*"$want"}" != "$got" ]; then printf 'ok    %-56s refused\n' "$name"
  else printf 'FAIL  %-56s rc=%s want=[%s] out=%s\n' "$name" "$rc" "$want" "$got"; fail=1; fi
}

echo "ABSENT IS IMAGE — every key-set measured across the fleet's 117 manifests"
ok "test only (69 files)"            'test:' '  - name: t' '    run: go test ./...'
ok "images + test (20)"              'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'test:' '  - name: t' '    run: go test ./...'
ok "images + kms + test (7)"         'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'kms:' '  path: deploy' 'test:' '  - name: t' '    run: go test ./...'
ok "images only (6)"                 'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a'
ok "images + test + version (3)"     'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'test: []' 'version: 1.2.3'
ok "client + test (2)"               'client:' '  version: pkg/version.go' 'test:' '  - name: t' '    run: pytest'
ok "deploy + images + kms (2)"       'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'kms:' '  org: hanzo' 'deploy:' '  services: [a]'
ok "images + kms + site (1)"         'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'kms: {}' 'site:' '  dir: out'
ok "images + version (1)"            'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'version: 9.9.9'
ok "test + version (1)"              'test:' '  - name: t' '    run: cargo test' 'version: 0.1.0'
ok "images + kms (1)"                'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a' 'kms:' '  environment: prod'
ok "build + e2e (1, hanzo/pricing)"  'build:' '  image: ghcr.io/hanzoai/pricing' 'e2e:' '  spec: tests/health.spec.ts'
ok "site + test (1)"                 'site:' '  dir: dist' 'test:' '  - name: t' '    run: npm test'
ok "binaries (read, declared by 0)"  'binaries:' '  - name: zip' '    main: ./cmd/zip'
ok "comment only (2: lux/kms, node)" '# the image is built by .hanzo/workflows/release.yml, not here' '# an images: block here would be a second publisher on one tag'
ok "empty file"                      ''
ok "explicit kind: image"            'kind: image' 'images:' '  - name: a' '    repo: ghcr.io/hanzoai/a'
ok "kind: with no value is absent"   'kind:' 'test:' '  - name: t' '    run: go test ./...'

# The pipeline reads a missing manifest as `image` too, matching every other
# manifest read in this file. It is not this step's job to notice — the test gate
# parses the same path with no fallback and dies there, loudly, on its own.
got=$(kind "$tmp/does-not-exist.yml" 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$got" = image ]; then printf 'ok    %-56s image\n' "no hanzo.yml at all"
else printf 'FAIL  %-56s rc=%s out=%s\n' "no hanzo.yml at all" "$rc" "$got"; fail=1; fi

echo
echo "NO LANE HERE — a real kind this pipeline does not deliver"
no "chart"    'kind: chart. This pipeline builds and pushes images and has no chart lane'       'kind: chart'
no "compose"  'kind: compose. This pipeline builds and pushes images and has no compose lane'   'kind: compose' 'path: compose.yml'
no "fn"       'kind: fn. This pipeline builds and pushes images and has no fn lane'             'kind: fn'
no "universe" 'kind: universe. This pipeline builds and pushes images and has no universe lane' 'kind: universe' 'path: charts'
# The one that is the whole point: a chart repository declares no `images:`, which
# is exactly the shape the image lane skips with exit 0. It must refuse anyway.
no "chart declaring no images, with a green test block" \
              'no chart lane' 'kind: chart' 'test:' '  - name: t' '    run: go test ./...'

echo
echo "NOT A KIND — refused by name, never defaulted to image"
no "a plural"            "not one of: $KINDS" 'kind: charts'
no "wrong case"          "not one of: $KINDS" 'kind: Chart'
no "a synonym"           "not one of: $KINDS" 'kind: helm'
no "a workload CR kind"  "not one of: $KINDS" 'kind: App'
no "empty string"        "not one of: $KINDS" 'kind: ""'
no "trailing space"      "not one of: $KINDS" 'kind: "chart "'
no "a mapping"           "not one of: $KINDS" 'kind:' '  path: chart'
no "a list"              "not one of: $KINDS" 'kind: [chart]'
no "a number"            "not one of: $KINDS" 'kind: 5'
no "a boolean"           "not one of: $KINDS" 'kind: true'

echo
# Membership is an exact comparison, so none of these is a match. The last row is
# the one that was RED before that: joining the names with spaces and asking for a
# substring accepts any adjacent pair of them.
echo "NOT A PATTERN, AND NOT A SUBSTRING — names are compared whole"
no "star"        "not one of: $KINDS" 'kind: "*"'
no "prefix star" "not one of: $KINDS" 'kind: "ima*"'
no "one char"    "not one of: $KINDS" 'kind: "?mage"'
no "a class"     "not one of: $KINDS" 'kind: "[i]mage"'
no "two names"   "not one of: $KINDS" 'kind: "image fn"'

echo
[ $fail = 0 ] && echo "all kind tests passed" || echo "kind tests FAILED"
exit $fail
