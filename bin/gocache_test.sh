#!/usr/bin/env bash
# Tests for bin/gocache. Offline: stub `curl` plays cloud's /v1/s3 (presign) and
# the store behind it, stub `go` names the caches, stub `zstd` is `cat`. What is
# tested is the protocol — who may write, what a reader trusts, and that a
# restored cache is byte-for-byte the saved one — not the network.
# Run: bash bin/gocache_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
GOCACHE_BIN="$PWD/bin/gocache"
fail=0
T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/store" "$T/repo"

cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
# The API answers presigned store:// URLs; the store is a directory.
o= w= m=GET d= up= url= auth=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) o=$2; shift ;; -w) w=$2; shift ;; -X) m=$2; shift ;; -d) d=$2; shift ;;
    -T) up=$2; shift ;; -H) case "$2" in Authorization:*) auth=$2 ;; esac; shift ;;
    -m) shift ;; -*) ;; *) url=$1 ;;
  esac
  shift
done
code() { [ -n "$w" ] && printf '%s' "$1"; }
case "$url" in
  store://*)
    k=${url#store://}
    if [ -n "$up" ]; then mkdir -p "$STORE/$(dirname "$k")"; cp "$up" "$STORE/$k"; echo "$k" >> "$STORE.puts"; exit 0; fi
    [ -f "$STORE/$k" ] || exit 22
    cp "$STORE/$k" "$o"; exit 0 ;;
  http://api.test/v1/s3/buckets)
    [ "$auth" = "Authorization: Bearer tok" ] || { code 401; exit 0; }
    code 201; exit 0 ;;
  http://api.test/v1/s3/buckets/ci-cache/objects)
    [ "$auth" = "Authorization: Bearer tok" ] || { code 401; exit 0; }
    k=$(printf '%s' "$d" | jq -r .key)
    printf '{"url":"store://%s","method":"PUT"}' "$k" > "$o"; code 200; exit 0 ;;
  http://api.test/v1/s3/buckets/ci-cache/objects/*)
    [ "$auth" = "Authorization: Bearer tok" ] || { code 401; exit 0; }
    printf '{"url":"store://%s","method":"GET"}' "${url#http://api.test/v1/s3/buckets/ci-cache/objects/}" > "$o"; code 200; exit 0 ;;
esac
code 404
EOF
cat > "$T/stub/go" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  GOMODCACHE) echo "$HOME/go/pkg/mod" ;; GOCACHE) echo "$HOME/.cache/go-build" ;;
  GOVERSION) echo go1.27.1 ;; GOARCH) echo amd64 ;;
esac
EOF
printf '#!/bin/sh\nexec cat\n' > "$T/stub/zstd"
chmod +x "$T/stub/"*
export PATH="$T/stub:$PATH" STORE="$T/store" HANZO_API=http://api.test HANZO_API_TOKEN=tok
export GITHUB_REPOSITORY=hanzoai/gateway GOCACHE_PART=4096
printf '{"repository":{"default_branch":"main"}}' > "$T/event.json"
printf 'example.com/a v1.0.0 h1:x=\n' > "$T/repo/go.sum"

# A pod: a fresh HOME and temp dir, as every runner job gets.
pod() { chmod -R u+w "$T/home" 2>/dev/null; rm -rf "$T/home" "$T/tmp"; mkdir -p "$T/home" "$T/tmp"; export HOME="$T/home" RUNNER_TEMP="$T/tmp"; }
# Go's module cache is read-only, which is what a real save and restore meet.
warm() {
  mkdir -p "$HOME/go/pkg/mod/example.com/a@v1.0.0" "$HOME/.cache/go-build/ab"
  head -c 20000 /dev/urandom > "$HOME/go/pkg/mod/example.com/a@v1.0.0/a.go"
  head -c 9000 /dev/urandom > "$HOME/.cache/go-build/ab/abcd-d"
  chmod -R a-w "$HOME/go/pkg/mod"
}
tree() { (cd "$HOME" && find go .cache/go-build -type f -exec sha256sum {} + 2>/dev/null | sort); }
run() { # run <event> <ref> <reftype> <cmd>
  GITHUB_EVENT_NAME=$1 GITHUB_REF_NAME=$2 GITHUB_REF_TYPE=$3 GITHUB_EVENT_PATH="$T/event.json" \
    GITHUB_OUTPUT="$T/out" bash "$GOCACHE_BIN" "$4" "$T/repo" > "$T/log" 2>&1
}
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; sed 's/^/        /' "$T/log"; fail=1; }
hit() { tail -1 "$T/out" 2>/dev/null | sed 's/^hit=//'; }
puts() { wc -l < "$STORE.puts" 2>/dev/null || echo 0; }
key=hanzoai/gateway/go1.27.1-amd64

pod; : > "$T/out"; run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && ok "an empty store is a miss, and exit 0" || no "an empty store is a miss, and exit 0"

pod; warm; run pull_request main branch save
[ ! -e "$STORE.puts" ] && ok "a pull request never writes" || no "a pull request never writes"

pod; warm; run push feature branch save
[ ! -e "$STORE.puts" ] && ok "a branch that is not the default never writes" || no "a branch that is not the default never writes"

pod; warm; want=$(tree); run push main branch save
n=$(ls "$STORE/$key/" 2>/dev/null | grep -c '\.tar\.zst\.')
[ -f "$STORE/$key/$(sha256sum "$T/repo/go.sum" | cut -c1-32).idx" ] && [ -f "$STORE/$key/latest" ] && [ "$n" -gt 1 ] \
  && ok "the default branch writes $n parts, then the index, then latest" || no "the default branch writes parts, index and latest"
[ "$(tail -2 "$STORE.puts" | head -1)" = "$key/$(sha256sum "$T/repo/go.sum" | cut -c1-32).idx" ] \
  && ok "the index is written after every part" || no "the index is written after every part"

before=$(puts); pod; warm; run push main branch save
[ "$(puts)" = "$before" ] && ok "a key already saved is not written again" || no "a key already saved is not written again"

pod; : > "$T/env"; GITHUB_ENV="$T/env" run push main branch restore
[ "$(hit)" = exact ] && [ "$(tree)" = "$want" ] && ok "a fresh pod restores the exact bytes that were saved" \
  || no "a fresh pod restores the exact bytes that were saved"
grep -qx "GOCACHE=$HOME/.cache/go-build" "$T/env" && grep -qx "GOMODCACHE=$HOME/go/pkg/mod" "$T/env" \
  && ok "later steps are pinned to the directories restored" || no "later steps are pinned to the directories restored"

pod; : > "$T/out"; HANZO_API_TOKEN=wrong run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && ok "a refused credential is a cold build, not a red one" || no "a refused credential is a cold build, not a red one"

printf 'example.com/a v1.0.1 h1:y=\n' >> "$T/repo/go.sum"
pod; run pull_request feature branch restore
[ "$(hit)" = partial ] && [ "$(tree)" = "$want" ] && ok "a go.sum the store has not seen restores the repo's latest" \
  || no "a go.sum the store has not seen restores the repo's latest"

old=$(cat "$STORE/$key/latest"); printf 'x' >> "$STORE/$key/$old.tar.zst.000"
pod; : > "$T/out"; run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && [ -z "$(tree)" ] && ok "an archive that does not match its index is never unpacked" \
  || no "an archive that does not match its index is never unpacked"

pod; : > "$T/out"; HANZO_API_TOKEN= run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && ok "no identity is a cold build" || no "no identity is a cold build"

# The workflow wires it: restore before the gate, save after it, both reading
# the module the Go provisioning found.
WF=.github/workflows/build.yml
grep -q '"$CI_HOME/bin/gocache" restore' "$WF" && grep -q '"$CI_HOME/bin/gocache" save' "$WF" \
  && ok "build.yml restores and saves through bin/gocache" || { printf 'FAIL  build.yml restores and saves through bin/gocache\n'; fail=1; }
grep -q 'cache: false' "$WF" && ! grep -q 'cache: ${{ inputs.go-cache' "$WF" \
  && ok "setup-go's own cache (GitHub's store) is off" || { printf "FAIL  setup-go's own cache (GitHub's store) is off\n"; fail=1; }

exit $fail
