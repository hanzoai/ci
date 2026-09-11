#!/usr/bin/env bash
# Tests for bin/imgtags, and for the property the script exists to hold: BOTH
# build lanes take their tags from it. Runs offline — the rule is a pure function
# of its arguments, and the lane check reads the workflow file.
# Run: bash bin/imgtags_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
IMGTAGS="$PWD/bin/imgtags"
WF=".github/workflows/build.yml"
fail=0

t() { # t <name> <want> <args...>
  local name="$1" want="$2"; shift 2
  got=$(bash "$IMGTAGS" "$@" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  [ $? -ne 0 ] && got="ERROR"
  [ -z "$got" ] && got="ERROR"
  if [ "$got" = "$want" ]; then printf 'ok    %-52s -> %s\n' "$name" "$got"
  else printf 'FAIL  %-52s -> %s (want %s)\n' "$name" "$got" "$want"; fail=1; fi
}

R=ghcr.io/hanzoai/x

# --- the rule ----------------------------------------------------------------
t "single-arch: sha carries the architecture" \
  "$R:sha-abc1234-amd64 $R:1.2.3" $R 1.2.3 abc1234 linux/amd64
t "multi-arch: the arch-neutral manifest list" \
  "$R:sha-abc1234 $R:1.2.3" $R 1.2.3 abc1234 linux/amd64,linux/arm64
t "release build: the git tag, plus its v-stripped alias" \
  "$R:sha-abc1234-amd64 $R:v1.2.3 $R:1.2.3 $R:latest" $R v1.2.3 abc1234 linux/amd64
t "a tag with no v publishes one version, not two" \
  "$R:sha-abc1234-amd64 $R:1.2.3" $R 1.2.3 abc1234 linux/amd64
t "tag-suffix qualifies every tag" \
  "$R:sha-abc1234-amd64-ce $R:1.2.3-ce" $R 1.2.3 abc1234 linux/amd64 ce
t "suffix on a release build too" \
  "$R:sha-abc1234-ee $R:v2.0.0-ee $R:2.0.0-ee $R:latest-ee" $R v2.0.0 abc1234 linux/amd64,linux/arm64 ee
t "a branch build writes no latest, whatever the platforms" \
  "$R:sha-abc1234 $R:1.2.3" $R 1.2.3 abc1234 linux/amd64,linux/arm64
t "arm64-only names arm64, not amd64" \
  "$R:sha-abc1234-arm64 $R:1.2.3" $R 1.2.3 abc1234 linux/arm64
t "space-separated platforms read the same as commas" \
  "$R:sha-abc1234 $R:1.2.3" $R 1.2.3 abc1234 "linux/amd64 linux/arm64"
t "the sha- ref is always first" \
  "$R:sha-abc1234-amd64 $R:v9.9.9 $R:9.9.9 $R:latest" $R v9.9.9 abc1234 linux/amd64

# --- the refusals ------------------------------------------------------------
t "no version: refuse, never fall back to the sha" "ERROR" $R "" abc1234 linux/amd64
t "no commit: refuse"                              "ERROR" $R 1.2.3 "" linux/amd64
t "no platforms: refuse"                           "ERROR" $R 1.2.3 abc1234 ""

# --- both lanes publish what it names ----------------------------------------
# The defect this script closes is a lane that builds its own ref. `delegate`
# posts ONE image to the build door, and when that one was assembled inline it
# was the sha- ref alone: the fleet pins semver, pin.sh refuses anything else,
# and every repo on that lane became undeployable while its runs stayed green.
# So the assertion is not "a semver appears somewhere" but "neither lane spells
# a tag itself" — the rule is above, and it is the only copy.
lane() { # lane <step name> -> that step's script
  awk -v s="      - name: $1" '
    $0 == s      { in_step = 1; next }
    in_step && /^      - name: / { exit }
    in_step      { print }
  ' "$WF"
}
l() { # l <step name>
  local name="$1" body
  body=$(lane "$name")
  if [ -z "$body" ]; then
    printf 'FAIL  %-52s -> step not found in %s\n' "$name" "$WF"; fail=1; return
  fi
  if echo "$body" | grep -q 'bin/imgtags'; then
    printf 'ok    %-52s -> takes its tags from bin/imgtags\n' "$name"
  else
    printf 'FAIL  %-52s -> does not call bin/imgtags\n' "$name"; fail=1
  fi
  if echo "$body" | grep -q 'sha-\${SHORT}'; then
    printf 'FAIL  %-52s -> spells a sha- ref inline; the shape is imgtags'"'"' to state\n' "$name"; fail=1
  else
    printf 'ok    %-52s -> spells no tag of its own\n' "$name"
  fi
}
l "Delegate build to the runner (mode=delegate)"
l "Build & push images (per hanzo.yml)"

# The delegate lane derives its number the same way the buildx lane does, so a
# branch build on either lane publishes the same series.
if lane "Delegate build to the runner (mode=delegate)" | grep -q 'bin/imgver'; then
  printf 'ok    %-52s -> derives its version with bin/imgver\n' "delegate lane"
else
  printf 'FAIL  %-52s -> does not call bin/imgver, so its number is a second rule\n' "delegate lane"; fail=1
fi

echo
[ $fail -eq 0 ] && echo "imgtags: all cases pass" || echo "imgtags: FAILURES"
exit $fail
