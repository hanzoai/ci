#!/usr/bin/env bash
# Tests for bin/rollback against a stub curl that serves a release from $SITE.
# Run: bash bin/rollback_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin/rollback"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/site/_site" "$T/site/a"
cat > "$T/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=/dev/stdout; url=
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -m|-H) shift ;; https://*) url=$1 ;; esac; shift; done
p=${url#https://s.test/}; p=${p%%\?*}
[ -f "$SITE/$p" ] && cp "$SITE/$p" "$out" || exit 22
STUB
chmod +x "$T/stub/curl"
export PATH="$T/stub:$PATH" SITE="$T/site"
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s (got: %s)\n' "$1" "$2"; fail=1; }
echo one > "$T/site/index.html"; echo two > "$T/site/a/b.js"
(cd "$T/site" && sha256sum index.html a/b.js) > "$T/site/_site/manifest.txt"
want=$(sha256sum < "$T/site/_site/manifest.txt" | cut -c1-64)

got=$(bash "$BIN" live https://s.test); [ "$got" = "$want" ] && ok "live names the release by its manifest" || no "live names the release by its manifest" "$got"
got=$(bash "$BIN" keep https://s.test "$T/kept")
[ "$got" = "$want" ] && cmp -s "$T/kept/index.html" "$T/site/index.html" && cmp -s "$T/kept/a/b.js" "$T/site/a/b.js" \
  && ok "keep fetches every file of the release, byte for byte" || no "keep fetches every file of the release, byte for byte" "$got"
echo changed > "$T/site/a/b.js"
bash "$BIN" keep https://s.test "$T/kept" > /dev/null 2>&1; [ $? = 3 ] && ok "a file that is not what the manifest says is not kept" || no "a file that is not what the manifest says is not kept" "$?"
rm "$T/site/a/b.js"
bash "$BIN" keep https://s.test "$T/kept" > /dev/null 2>&1; [ $? = 3 ] && ok "a file that does not download is not kept" || no "a file that does not download is not kept" "$?"
echo two > "$T/site/a/b.js"
ROLLBACK_MAX_FILES=1 bash "$BIN" keep https://s.test "$T/kept" > /dev/null 2>&1; [ $? = 3 ] && ok "a release past the file bound is not kept" || no "a release past the file bound is not kept" "$?"
rm "$T/site/_site/manifest.txt"
bash "$BIN" live https://s.test > /dev/null 2>&1; [ $? = 3 ] && ok "a site with no manifest has no release to name" || no "a site with no manifest has no release to name" "$?"
bash "$BIN" live http://s.test > /dev/null 2>&1; [ $? = 2 ] && ok "only an https host is read" || no "only an https host is read" "$?"
exit $fail
