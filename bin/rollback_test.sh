#!/usr/bin/env bash
# Tests for bin/rollback against a stub curl that serves a releases list from
# $LIST and records each activation it is asked for.
# Run: bash bin/rollback_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin/rollback"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=/dev/null; url=
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -w|-m|-H|-X) shift ;; http*) url=$1 ;; esac; shift; done
case "$url" in
  */activate) echo "$url" >> "$CALLS"; printf 200 ;;
  */releases) cat "$LIST" > "$out"; printf 200 ;;
  *) printf 404 ;;
esac
STUB
chmod +x "$T/stub/curl"
export PATH="$T/stub:$PATH" HANZO_DEPLOY_TOKEN=sk-test CALLS="$T/calls" LIST="$T/list" HANZO_API=https://api.test
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s (got: %s)\n' "$1" "$2"; fail=1; }

echo '[{"releaseId":"r3","active":true,"url":"https://s.test"},{"releaseId":"r2","active":false},{"releaseId":"r1","active":false}]' > "$LIST"
got=$(bash "$BIN" mark site)
[ "$got" = "site r3 r2 https://s.test" ] && ok "mark names what serves and the release before it" || no "mark names what serves and the release before it" "$got"

: > "$CALLS"; bash "$BIN" undo site r3 r2 > /dev/null
[ "$(cat "$CALLS")" = "https://api.test/v1/project/site/releases/r2/activate" ] && ok "undo serves the release before again" || no "undo serves the release before again" "$(cat "$CALLS")"

echo '[{"releaseId":"r4","active":true},{"releaseId":"r3","active":false}]' > "$LIST"
: > "$CALLS"; out=$(bash "$BIN" undo site r3 r2)
[ ! -s "$CALLS" ] && grep -q 'a newer publish stands' <<<"$out" && ok "undo leaves a newer publish serving" || no "undo leaves a newer publish serving" "$out"

echo '[{"releaseId":"r1","active":true}]' > "$LIST"
got=$(bash "$BIN" mark site)
[ "$got" = "site r1 - -" ] && ok "a first release has nothing before it" || no "a first release has nothing before it" "$got"
bash "$BIN" undo site r1 - > /dev/null 2>&1; [ $? = 1 ] && ok "undo with nothing before it fails" || no "undo with nothing before it fails" "$?"

echo '[{"releaseId":"r3","active":true},{"releaseId":"r2","active":false}]' > "$LIST"
: > "$CALLS"; out=$(bash "$BIN" undo site r3 r3)
[ ! -s "$CALLS" ] && grep -q 'nothing to undo' <<<"$out" && ok "a publish that changed nothing is not undone" || no "a publish that changed nothing is not undone" "$out"

bash "$BIN" mark 'Bad/slug' > /dev/null 2>&1; [ $? = 2 ] && ok "a slug that is not one is refused" || no "a slug that is not one is refused" "$?"
exit $fail
