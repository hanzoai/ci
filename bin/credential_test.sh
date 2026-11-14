#!/usr/bin/env bash
# Tests for `credential`, which picks the token the cut pushes a regenerated
# client with. There is no bin/credential: the function lives in
# .github/workflows/build.yml, and this suite lifts it out and runs that text.
#
# Each host takes its own token and refuses the other's. github.com gets the
# hanzo-platform App's write token for the repository (GIT_PUSH_TOKEN, minted by
# bin/apptoken for this push), which starts workflows, so the tag it carries
# reaches the publish lane; the forge gets the org's IAM token. No other GitHub
# credential is read: a leftover GH_PAT or GIT_TOKEN in the environment is not one.
#
# Offline. Run: bash bin/credential_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

sed -n '/^          # credential BEGIN$/,/^          # credential END$/p' "$DEF" | sed 's/^          //' > "$tmp/credential.sh"
grep -q '^credential() {' "$tmp/credential.sh" || {
  echo "FAIL  could not lift credential() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }

# check <name> <remote> <want token | refuses> [VAR=value ...]
check() {
  local name=$1 remote=$2 want=$3 out rc; shift 3
  out=$(env -i PATH="$PATH" "$@" bash -c '. "$1"; credential "$2"' _ "$tmp/credential.sh" "$remote" 2>"$tmp/err"); rc=$?
  if [ "$want" = refuses ]; then
    if [ "$rc" != 0 ] && [ -z "$out" ] && grep -q '::error::' "$tmp/err"; then echo "ok   $name"; else
      echo "FAIL $name: want a refusal, got rc=$rc out=[$out] err=[$(cat "$tmp/err")]"; fail=1; fi
    return
  fi
  if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then echo "ok   $name"; else
    echo "FAIL $name: want [$want], got rc=$rc out=[$out] err=[$(cat "$tmp/err")]"; fail=1; fi
}

gh=https://github.com/hanzoai/python-sdk
forge=https://git.hanzo.ai/hanzoai/python-sdk
check "github.com takes the App's write token"            "$gh" app     GIT_PUSH_TOKEN=app HANZO_API_TOKEN=iam
check "a read token is not a write token"                  "$gh" refuses GIT_TOKEN=read HANZO_API_TOKEN=iam
check "a leftover GH_PAT is no credential"                 "$gh" refuses GH_PAT=pat
check "an empty write token is no token"                   "$gh" refuses GIT_PUSH_TOKEN=
check "github.com is never handed the IAM token"           "$gh" refuses HANZO_API_TOKEN=iam
check "github.com with no token refuses"                   "$gh" refuses
check "the forge takes the IAM token"                      "$forge" iam  GIT_PUSH_TOKEN=app GIT_TOKEN=read HANZO_API_TOKEN=iam
check "the forge's in-cluster address takes the IAM token" http://git.hanzo.svc:3000/hanzoai/python-sdk iam HANZO_API_TOKEN=iam
check "the forge is never handed a GitHub token"           "$forge" refuses GIT_PUSH_TOKEN=app GIT_TOKEN=read
check "a host that only starts with github.com is not it"  https://github.com.example/hanzoai/x refuses GIT_PUSH_TOKEN=app

exit $fail
