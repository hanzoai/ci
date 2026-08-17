#!/usr/bin/env bash
# Tests for the `tally` function that decides whether a test gate reported any
# result. There is no bin/tally: the function lives inside the one definition of
# the pipeline, .hanzo/workflows/build.yml, and this suite LIFTS IT OUT and runs
# it. So there is nothing to keep in step — what is tested here is the same text
# the runner executes, and a rule edited in one place cannot drift from a rule
# tested in another.
#
# It has to be lifted rather than called because a run cannot reach a new file in
# this repo: the tools checkout derives its ref from GITHUB_WORKFLOW_REF, which
# git.hanzo.ai does not set, so $CI_HOME resolves to whatever `v1` names rather
# than to the tag the caller pinned.
#
# Every fixture is output captured from a real gate in the fleet, colour bytes
# and all, because colour is what the first version of this got wrong.
# Offline and deterministic: strings in, a number out, no network.
# Run: bash bin/tally_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=.hanzo/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

sed -n '/^          # tally BEGIN$/,/^          # tally END$/p' "$DEF" | sed 's/^          //' > "$tmp/tally.sh"
grep -q '^tally() {' "$tmp/tally.sh" || {
  echo "FAIL  could not lift tally() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }
# shellcheck disable=SC1090
. "$tmp/tally.sh"

E=$'\033'   # the escapes every JS and Python runner writes on CI

# t <name> <want> <log...>
t() {
  local name=$1 want=$2; shift 2
  printf '%s\n' "$@" > "$tmp/log"
  local got; got=$(tally "$tmp/log")
  if [ "$got" = "$want" ]; then printf 'ok    %-58s %s\n' "$name" "$got"
  else printf 'FAIL  %-58s got=%s want=%s\n' "$name" "$got" "$want"; fail=1; fi
}

echo "COUNTED — a runner reporting results"
t "go, per package"                1 "ok  	github.com/hanzoai/ci	0.005s"
t "go, three packages"             3 "ok  	x/a	0.1s" "ok  	x/b	(cached)" "ok  	x/c	0.2s"
t "go -v, per test beats package"  3 "--- PASS: TestA (0.00s)" "--- PASS: TestB (0.00s)" "--- FAIL: TestC (0.00s)" "FAIL	x/a	0.1s"
t "go, a failing package"          1 "FAIL	github.com/hanzoai/x	0.104s"
t "gotestsum, summed over runs"   80 "DONE 40 tests in 3.399s" "DONE 40 tests in 1.100s"
t "cargo"                          5 "test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured"
t "cargo, with failures"           7 "test result: FAILED. 5 passed; 2 failed; 0 ignored"
t "rust -v"                        3 "test tally::a ... ok" "test tally::b ... FAILED" "test tally::c ... ignored"
t "mocha"                        415 "  412 passing (2s)" "  3 failing"
# ava attaches the count to `tests` rather than to the verb, so the rules that
# read the word before passed/failed find `tests` there. Both captured from the
# fleet: hanzoai/openid-client and hanzoai/insights-node.
t "ava"                           94 "  94 tests passed"
t "ava, with a failure"           94 "  1 test failed" "  93 tests passed"
t "bun test, per case"             4 "(pass) api > get [0.52ms]" "(pass) api > put [0.3ms]" "(pass) api > del [0.2ms]" "(fail) api > patch [0.1ms]"
t "TAP"                            2 "ok 1 - the first" "not ok 2 - the second"
t "a bin/*_test.sh suite"         17 "  ok    clean repo is green" "  ok    the mark is refused" "" "vendormark_test: 17 passed, 0 failed"
t "pytest, plain summary"         90 "======================== 90 passed, 15 skipped in 0.34s ========================"
t "pytest, node ids"               3 "tests/t.py::TestA::test_x PASSED" "tests/t.py::TestA::test_y PASSED" "tests/t.py::test_z FAILED"

echo
echo "COLOUR — the same runners as CI actually writes them"
t "pytest in colour"              90 "tests/t.py::TestA::test_x ${E}[32mPASSED${E}[0m" \
                                     "${E}[32m======================== ${E}[32m${E}[1m90 passed${E}[0m, ${E}[33m15 skipped${E}[0m${E}[32m in 0.34s${E}[0m${E}[32m ========================${E}[0m"
t "vitest in colour"               9 "${E}[2m Test Files ${E}[22m ${E}[1m${E}[32m1 passed${E}[39m${E}[22m${E}[90m (1)${E}[39m" \
                                     "${E}[2m      Tests ${E}[22m ${E}[1m${E}[32m9 passed${E}[39m${E}[22m${E}[90m (9)${E}[39m"
t "jest in colour"               412 "${E}[1mTests:${E}[22m       ${E}[1m${E}[32m411 passed${E}[39m${E}[22m, ${E}[1m1 failed${E}[22m, 412 total"
t "a progress bar's carriage returns" 1 $'#=#=#     50.0%\r########  100.0%\rok  	x/a	0.1s'

echo
echo "NOT COUNTED — a gate that is not a test, and a runner that ran nothing"
t "empty output"                   0 ""
t "go, no test files"              0 "?   	github.com/hanzoai/x	[no test files]"
t "go, build tag excluded the suite" 0 "testing: warning: no tests to run" "PASS" "ok  	x/a	0.002s [no tests to run]"
t "an assertion gate saying OK:"   0 "OK: one definition (2058 lines), no forwarder, no second address"
t "a linter"                       0 "shell: no authored utility classes in 36 files ✓" "☔️ success workspaces valid!"
t "a typescript build"             0 "> hanzoai@2.2.10 build" "> tsc && tsc -p tsconfig.esm.json"
t "npm install noise"              0 "added 30 packages in 1s" "14 high severity vulnerabilities" "60 packages are looking for funding"
t "a turbo build"                  0 "• Packages in scope: @hanzo/gui, @hanzogui/core" "• Running build in 197 packages" "cache bypass, force executing 5701289d"
t "a word ending in ok"            0 "notebook  something" "OK" "hook  fired"
t "vitest reporting nothing"       0 "${E}[2m      Tests ${E}[22m ${E}[1m${E}[32m0 passed${E}[39m${E}[22m${E}[90m (0)${E}[39m"

echo
echo "NO DOUBLE COUNT — one run reported twice is still one run"
t "cargo prints its own total once" 5 "test tally::a ... ok" "test tally::b ... ok" "test tally::c ... ok" "test tally::d ... ok" "test tally::e ... ok" "test result: ok. 5 passed; 0 failed"
t "pytest ids and summary agree"   3 "tests/t.py::a PASSED" "tests/t.py::b PASSED" "tests/t.py::c PASSED" "===== 3 passed in 0.1s ====="
t "vitest files line is not a total" 9 "${E}[2m Test Files ${E}[22m 1 passed (1)" "${E}[2m      Tests ${E}[22m 9 passed (9)"

echo
[ $fail = 0 ] && echo "all tally tests passed" || echo "tally tests FAILED"
exit $fail
