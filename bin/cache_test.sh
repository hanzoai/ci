#!/usr/bin/env bash
# Tests for bin/cache. Offline: stub `curl` plays cloud's /v1/s3 (presign) and
# the store behind it, stub `zstd` is `cat`. What is tested is the protocol —
# who may write, what a reader trusts, that a restored directory is byte for
# byte the saved one wherever it lands, and that no failure turns a build red.
# Run: bash bin/cache_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CACHE_BIN="$PWD/bin/cache"
fail=0
T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/store"

cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
# The API answers presigned store:// URLs; the store is a directory.
# REFUSE_PUT=<n>: the store refuses the n-th upload and every one after it.
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
    if [ -n "$up" ]; then
      if [ -n "${REFUSE_PUT:-}" ]; then
        c=$(( $(cat "$STORE.tries" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STORE.tries"
        [ "$c" -lt "$REFUSE_PUT" ] || exit 22
      fi
      mkdir -p "$STORE/$(dirname "$k")"; cp "$up" "$STORE/$k"; echo "$k" >> "$STORE.puts"; exit 0
    fi
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
printf '#!/bin/sh\nexec cat\n' > "$T/stub/zstd"
chmod +x "$T/stub/"*
export PATH="$T/stub:$PATH" STORE="$T/store" HANZO_API=http://api.test HANZO_API_TOKEN=tok
export GITHUB_REPOSITORY=hanzoai/dev CACHE_PART=4096
printf '{"repository":{"default_branch":"main"}}' > "$T/event.json"

# A pod: a fresh HOME and temp dir, as every runner job gets.
pod() { chmod -R u+w "$T/home" 2>/dev/null; rm -rf "${T:?}/home" "${T:?}/tmp"; mkdir -p "$T/home" "$T/tmp"; export HOME="$T/home" RUNNER_TEMP="$T/tmp"; }
# Two directories a build fills: objects, and downloads with a link inside.
warm() {
  mkdir -p "$HOME/objs/a/b" "$HOME/dl/cache" "$HOME/dl/src"
  head -c 20000 /dev/urandom > "$HOME/objs/a/b/obj1"
  head -c 9000 /dev/urandom > "$HOME/objs/a/obj2"
  head -c 7000 /dev/urandom > "$HOME/dl/cache/crate-1.0.crate"
  ln -s ../cache/crate-1.0.crate "$HOME/dl/src/link"
}
tree() { (cd "$HOME" && find objs dl -exec sh -c 'for f; do if [ -L "$f" ]; then echo "L $f $(readlink "$f")"; elif [ -f "$f" ]; then sha256sum "$f"; fi; done' _ {} + 2>/dev/null | sort); }
run() { # run <event> <ref> <reftype> <cmd> [key]
  GITHUB_EVENT_NAME=$1 GITHUB_REF_NAME=$2 GITHUB_REF_TYPE=$3 GITHUB_EVENT_PATH="$T/event.json" \
    GITHUB_OUTPUT="$T/out" bash "$CACHE_BIN" "$4" rust-abc-x86_64 "${5:-k1}" objs="$HOME/objs" dl="$HOME/dl" > "$T/log" 2>&1
}
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; sed 's/^/        /' "$T/log"; fail=1; }
hit() { tail -1 "$T/out" 2>/dev/null | sed 's/^hit=//'; }
puts() { wc -l < "$STORE.puts" 2>/dev/null || echo 0; }
pre=hanzoai/dev/rust-abc-x86_64

for bad in "a/b k1 x=/d" "a .. x=/d" ".a k1 x=/d" "a k1 x" "a k1 =/d" "a k1 x/y=/d" "a k1"; do
  # shellcheck disable=SC2086 # each case is three words on purpose
  bash "$CACHE_BIN" restore $bad > "$T/log" 2>&1; rc=$?
  [ "$rc" = 2 ] || { no "a malformed call is refused: restore $bad (exit $rc)"; continue; }
done
ok "a name, key or label that is not one plain segment is refused before any request"

pod; : > "$T/out"; run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && ok "an empty store is a miss, and exit 0" || no "an empty store is a miss, and exit 0"

pod; warm; run pull_request main branch save
[ ! -e "$STORE.puts" ] && ok "a pull request never writes" || no "a pull request never writes"

pod; warm; run push feature branch save
[ ! -e "$STORE.puts" ] && ok "a branch that is not the default never writes" || no "a branch that is not the default never writes"

pod; warm; REFUSE_PUT=3 run push main branch save; rc=$?; rm -f "$STORE.tries"
[ "$rc" = 0 ] && [ ! -e "$STORE/$pre/k1.idx" ] && [ ! -e "$STORE/$pre/latest" ] \
  && ok "a part the store refuses is a notice, and no index names the half-written key" \
  || no "a part the store refuses is a notice, and no index names the half-written key"
rm -rf "${STORE:?}"/* "$STORE.puts"

pod; warm; want=$(tree); run push main branch save
n=$(find "$STORE/$pre" -name 'k1.tar.zst.*' | wc -l)
[ -f "$STORE/$pre/k1.idx" ] && [ "$(cat "$STORE/$pre/latest")" = k1 ] && [ "$n" -gt 1 ] \
  && ok "the default branch writes $n parts, then the index, then latest" || no "the default branch writes parts, index and latest"
[ "$(tail -2 "$STORE.puts" | head -1)" = "$pre/k1.idx" ] && [ "$(tail -1 "$STORE.puts")" = "$pre/latest" ] \
  && ok "the index is written after every part" || no "the index is written after every part"

before=$(puts); pod; warm; run push main branch save
[ "$(puts)" = "$before" ] && ok "a key already saved is not written again" || no "a key already saved is not written again"

pod; : > "$T/out"; run push main branch restore
[ "$(hit)" = exact ] && [ "$(tree)" = "$want" ] && ok "a fresh pod restores the exact bytes and links that were saved" \
  || no "a fresh pod restores the exact bytes and links that were saved"
[ -z "$(ls "$T/tmp")" ] && ok "restore leaves nothing behind in RUNNER_TEMP" || no "restore leaves nothing behind in RUNNER_TEMP"

pod; mkdir -p "$HOME/dl/cache"; echo mine > "$HOME/dl/cache/other.crate"; : > "$T/out"; run push main branch restore
[ "$(hit)" = exact ] && [ "$(cat "$HOME/dl/cache/other.crate")" = mine ] && [ -f "$HOME/dl/cache/crate-1.0.crate" ] \
  && [ -L "$HOME/dl/src/link" ] && ok "a target that is not empty is merged into, not replaced" || no "a target that is not empty is merged into, not replaced"

pod; : > "$T/out"
GITHUB_EVENT_NAME=push GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch GITHUB_EVENT_PATH="$T/event.json" GITHUB_OUTPUT="$T/out" \
  bash "$CACHE_BIN" restore rust-abc-x86_64 k1 objs="$HOME/elsewhere/o" git="$HOME/git" > "$T/log" 2>&1
[ "$(hit)" = exact ] && [ -f "$HOME/elsewhere/o/a/b/obj1" ] && [ ! -e "$HOME/git" ] \
  && ok "a label lands wherever the caller names it now, and one the archive lacks stays cold" \
  || no "a label lands wherever the caller names it now, and one the archive lacks stays cold"

pod; : > "$T/out"; HANZO_API_TOKEN=wrong run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && ok "a refused credential is a cold build, not a red one" || no "a refused credential is a cold build, not a red one"

pod; : > "$T/out"; run pull_request feature branch restore k9
[ "$(hit)" = partial ] && [ "$(tree)" = "$want" ] && ok "a key the store has not seen restores the newest one saved" \
  || no "a key the store has not seen restores the newest one saved"

printf '../../escape\n' > "$STORE/$pre/latest"
pod; : > "$T/out"; run push main branch restore k9
[ "$(hit)" = miss ] && ok "a latest that is not one plain key is never followed" || no "a latest that is not one plain key is never followed"
printf 'k1\n' > "$STORE/$pre/latest"

printf 'x' >> "$STORE/$pre/k1.tar.zst.000"
pod; : > "$T/out"; run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && [ -z "$(tree)" ] && ok "an archive that does not match its index is never unpacked" \
  || no "an archive that does not match its index is never unpacked"

pod; : > "$T/out"; HANZO_API_TOKEN='' run push main branch restore
[ $? = 0 ] && [ "$(hit)" = miss ] && ok "no identity is a cold build" || no "no identity is a cold build"

pod; warm; run push v1.2.3 tag save k2
[ -f "$STORE/$pre/k2.idx" ] && [ "$(cat "$STORE/$pre/latest")" = k2 ] && ok "a tag writes" || no "a tag writes"

before=$(puts); pod; run push main branch save k3
[ "$(puts)" = "$before" ] && ok "no directory to save writes nothing" || no "no directory to save writes nothing"

exit $fail
