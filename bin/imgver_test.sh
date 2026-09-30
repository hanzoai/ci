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
  IMGVER_VERSION="$1" IMGVER_PUBLISHED="$2" GH_PAT= GIT_TOKEN= GITHUB_TOKEN= \
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

# --- the token ladder --------------------------------------------------------
# A stub curl answers only the token it is told to, so the published floor
# shows which rung imgver read the registry with.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "Authorization: Bearer $ANSWER" ] && { echo '[{"metadata":{"container":{"tags":["v4.0.1"]}}}]'; exit 0; }; done
exit 22
STUB
chmod +x "$tmp/bin/curl"
l() { # l <name> <GH_PAT> <GIT_TOKEN> <GITHUB_TOKEN> <answering token> <want>
  got=$(PATH="$tmp/bin:$PATH" ANSWER="$5" IMGVER_VERSION= IMGVER_PUBLISHED= GH_PAT="$2" GIT_TOKEN="$3" GITHUB_TOKEN="$4" \
    bash "$IMGVER" ghcr.io/hanzo-inc/test "$tmp" 2>/dev/null) || got=ERROR
  if [ "$got" = "$6" ]; then printf 'ok    %-52s -> %s\n' "$1" "$got"
  else printf 'FAIL  %-52s -> %s (want %s)\n' "$1" "$got" "$6"; fail=1; fi
}
rm -rf "$tmp"/m
l "GH_PAT first"                                 pat kms auto pat  4.0.2
l "no GH_PAT: the KMS GitHub token"              ""  kms auto kms  4.0.2
l "neither: the automatic token"                 ""  ""  auto auto 4.0.2
l "a rung that cannot read is not skipped past"  ""  kms auto auto ERROR

echo
[ $fail -eq 0 ] && echo "imgver: all cases pass" || echo "imgver: FAILURES"
exit $fail
