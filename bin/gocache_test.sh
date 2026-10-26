#!/usr/bin/env bash
# Tests for bin/gocache, the job's side of gocache/ (whose own suite, `go test`
# in gocache/, covers the store, the packs and the protocol). What is pinned
# here is what a job sees: an old toolchain or a missing module is a cold build
# and exit 0, a started cache is wired into every later step through
# GITHUB_ENV, a go build through it works with no store at all, GOPROXY keeps
# what it named behind the cache, and save stops what restore started.
# Run: bash bin/gocache_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/bin/gocache"
fail=0
T=$(mktemp -d); trap 'pkill -f "$T/tmp/gocache/gocache serve" 2>/dev/null; chmod -R u+w "$T"; rm -rf "$T"' EXIT
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; sed 's/^/        /' "$T/log"; fail=1; }
pod() { rm -rf "$T/tmp" "$T/env"; mkdir -p "$T/tmp"; : > "$T/env"; }
mkdir -p "$T/m" "$T/stub"
printf 'module example.com/m\n\ngo 1.24\n' > "$T/m/go.mod"
printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("m") }\n' > "$T/m/main.go"
printf '{"repository":{"default_branch":"main"}}' > "$T/event.json"
run() { # run <event> <ref> <cmd> [dir]
  RUNNER_TEMP="$T/tmp" GITHUB_ENV="$T/env" GITHUB_REPOSITORY=hanzoai/x GITHUB_EVENT_NAME=$1 \
    GITHUB_REF_NAME=$2 GITHUB_REF_TYPE=branch GITHUB_EVENT_PATH="$T/event.json" HANZO_API_TOKEN= \
    bash "$BIN" "$3" "${4:-$T/m}" > "$T/log" 2>&1
}

cat > "$T/stub/go" <<'EOF'
#!/bin/sh
[ "$2" = GOVERSION ] && echo go1.23.4
EOF
chmod +x "$T/stub/go"
pod; PATH="$T/stub:$PATH" run push main restore
[ $? = 0 ] && grep -q 'predates GOCACHEPROG' "$T/log" && [ ! -s "$T/env" ] \
  && ok "a toolchain older than 1.24 builds cold, and exit 0" || no "a toolchain older than 1.24 builds cold, and exit 0"

pod; run push main restore "$T/stub"
[ $? = 0 ] && grep -q 'has no go.mod' "$T/log" && [ ! -s "$T/env" ] \
  && ok "no go.mod is a notice, not a red gate" || no "no go.mod is a notice, not a red gate"

pod; run push main save
[ $? = 0 ] && grep -q 'nothing to save' "$T/log" && ok "save with nothing started is a notice" || no "save with nothing started is a notice"

if ! command -v go >/dev/null 2>&1; then
  printf 'skip  the rest builds with go, which this runner does not have\n'
  exit $fail
fi

pod; run push main restore
grep -q '^GOCACHEPROG=.*/gocache connect .*/sock .*/dir$' "$T/env" && grep -q '^GOPROXY=http://127\.0\.0\.1:[0-9]*|' "$T/env" \
  && grep -q '^GOMODCACHE=' "$T/env" && grep -q '^GOCACHE=' "$T/env" \
  && ok "restore wires GOCACHEPROG, GOPROXY and both cache directories into later steps" \
  || no "restore wires GOCACHEPROG, GOPROXY and both cache directories into later steps"
up=$(go env GOPROXY)
[ "$(sed -n 's/^GOPROXY=http:\/\/127\.0\.0\.1:[0-9]*|//p' "$T/env")" = "${up//,/|}" ] \
  && ok "GOPROXY keeps what it named behind the cache, each falling through to the next" || no "GOPROXY keeps what it named behind the cache, each falling through to the next"
grep -q 'writing what this job builds' "$T/log" && ok "the default branch may write" || no "the default branch may write"

( set -a; . "$T/env"; set +a; cd "$T/m" && GOWORK=off GOFLAGS= go build -o "$T/m.out" . ) > "$T/log" 2>&1 && "$T/m.out" | grep -qx m \
  && ok "a go build runs through the cache with no store behind it" || no "a go build runs through the cache with no store behind it"

run push main save
grep -q 'puts' "$T/log" && ! pgrep -f "$T/tmp/gocache/gocache serve" >/dev/null \
  && ok "save reports what the cache did, and stops it" || no "save reports what the cache did, and stops it"

pod; run pull_request feature restore
grep -q 'read only' "$T/log" && ok "a pull request reads and never writes" || no "a pull request reads and never writes"
run pull_request feature save

pod; GOPROXY=off run push main restore
grep -qx 'GOPROXY=off' "$T/env" && ok "a GOPROXY that forbids downloads is left as it is" || no "a GOPROXY that forbids downloads is left as it is"
GOPROXY=off run push main save

# The workflow wires it: start before the gate, save after it red or green,
# both reading the module the Go provisioning found, and the gates run from
# one path on every runner.
WF=.github/workflows/build.yml
grep -q '"$CI_HOME/bin/gocache" restore' "$WF" && grep -q '"$CI_HOME/bin/gocache" save' "$WF" \
  && ok "build.yml starts and saves through bin/gocache" || { printf 'FAIL  build.yml starts and saves through bin/gocache\n'; fail=1; }
grep -q "if: (success() || failure()) && steps.gomod.outputs.file != ''" "$WF" \
  && ok "the save runs after a red gate too" || { printf 'FAIL  the save runs after a red gate too\n'; fail=1; }
grep -q 'src="/var/tmp/src/${GITHUB_REPOSITORY' "$WF" \
  && ok "gates run from one path on every runner" || { printf 'FAIL  gates run from one path on every runner\n'; fail=1; }
grep -q 'cache: false' "$WF" && ! grep -q 'cache: ${{ inputs.go-cache' "$WF" \
  && ok "setup-go's own cache (GitHub's store) is off" || { printf "FAIL  setup-go's own cache (GitHub's store) is off\n"; fail=1; }

exit $fail
