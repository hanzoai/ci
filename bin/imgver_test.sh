#!/usr/bin/env bash
# Tests for bin/imgver. Runs offline: no GH_PAT means no registry read, so the
# published floor is injected through IMGVER_PUBLISHED and every case is
# deterministic. Run: bash bin/imgver_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
IMGVER="$PWD/bin/imgver"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

run() { # run <declared-env> <published> <ctx>
  IMGVER_VERSION="$1" IMGVER_PUBLISHED="$2" GH_PAT= GITHUB_TOKEN= \
    bash "$IMGVER" ghcr.io/hanzoai/test "$3" 2>/dev/null
}
t() { # t <name> <declared> <published> <ctx> <want>
  got=$(run "$2" "$3" "$4"); rc=$?
  [ $rc -ne 0 ] && got="ERROR"
  if [ "$got" = "$5" ]; then printf 'ok    %-52s -> %s\n' "$1" "$got"
  else printf 'FAIL  %-52s -> %s (want %s)\n' "$1" "$got" "$5"; fail=1; fi
}

# --- the derivation ---------------------------------------------------------
t "registry ahead: next patch, monotonic"        1.2.3    1.2.7  "$tmp" 1.2.8
t "human bumped the minor: honour it verbatim"   1.3.0    1.2.8  "$tmp" 1.3.0
t "same number published: never 2 digests/name"  1.2.3    1.2.3  "$tmp" 1.2.4
t "no manifest version: registry carries it"     ""       1.2.7  "$tmp" 1.2.8
t "nothing published: seed at declared"          1.2.3    ""     "$tmp" 1.2.3
t "major bump honoured"                          2.0.0    1.9.9  "$tmp" 2.0.0
t "sort -V not lexical (1.2.10 > 1.2.9)"         1.2.9    1.2.10 "$tmp" 1.2.11
t "cloud's real series"                          1.801.341 1.801.341 "$tmp" 1.801.342
t "stale manifest cannot drag series backwards"  0.0.1    0.9.0  "$tmp" 0.9.1
t "no version anywhere: fail loud, never sha"    ""       ""     "$tmp" ERROR
t "leading v stripped"                           v1.4.0   ""     "$tmp" 1.4.0
t "0.0.0 workspace stub is not a version"        0.0.0    1.1.1  "$tmp" 1.1.2
t "non-semver declared is ignored"               "1.2"    2.0.0  "$tmp" 2.0.1

# --- manifest discovery ------------------------------------------------------
m() { rm -rf "$tmp"/m; mkdir -p "$tmp"/m; }
m; echo '{"version":"3.4.5"}' > "$tmp/m/package.json"
t "package.json"                                 "" "" "$tmp/m" 3.4.5
m; printf '[package]\nname="x"\nversion = "6.7.8"\n' > "$tmp/m/Cargo.toml"
t "Cargo.toml [package]"                         "" "" "$tmp/m" 6.7.8
m; printf '[workspace.package]\nversion = "1.45.2"\n' > "$tmp/m/Cargo.toml"
t "Cargo.toml [workspace.package] (index's shape)" "" "" "$tmp/m" 1.45.2
m; echo "9.9.9" > "$tmp/m/VERSION"
t "VERSION file"                                 "" "" "$tmp/m" 9.9.9
m; printf '[project]\nversion = "2.3.4"\n' > "$tmp/m/pyproject.toml"
t "pyproject.toml"                               "" "" "$tmp/m" 2.3.4
m; echo '{"name":"x"}' > "$tmp/m/package.json"
t "package.json with no version key -> ERROR"    "" "" "$tmp/m" ERROR
m; echo '{"version":"0.0.0"}' > "$tmp/m/package.json"
t "workspace stub package.json -> ERROR"         "" "" "$tmp/m" ERROR
m; echo '{"version":"1.0.0"}' > "$tmp/m/package.json"
t "IMGVER_VERSION overrides the manifest"        5.5.5 "" "$tmp/m" 5.5.5
m; echo '{"version":"1.0.0"}' > "$tmp/m/package.json"
t "resolver expression <file>:<command>"         "package.json:echo 7.7.7" "" "$tmp/m" 7.7.7

echo
[ $fail -eq 0 ] && echo "imgver: all cases pass" || echo "imgver: FAILURES"
exit $fail
