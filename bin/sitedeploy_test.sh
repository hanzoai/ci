#!/usr/bin/env bash
# Tests for bin/sitedeploy. Runs OFFLINE: SITEDEPLOY_PLAN=1 stops the script
# before the first network call and prints the manifest it would upload, so every
# case here is deterministic and needs no token, no bucket and no cluster.
# Run: bash bin/sitedeploy_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SD="$PWD/bin/sitedeploy"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

plan() { SITEDEPLOY_PLAN=1 bash "$SD" a-slug "$1" 2>&1; }
t() { # t <name> <got> <want>
  if [ "$2" = "$3" ]; then printf 'ok    %-56s -> %s\n' "$1" "$2"
  else printf 'FAIL  %-56s -> %s (want %s)\n' "$1" "$2" "$3"; fail=1; fi
}
# field <dir> <key> <col>  — the ctype (2) or cachectl (3) column for one key
field() { plan "$1" | awk -F'\t' -v k="$2" -v c="$3" '$1==k{print $c}'; }

site="$tmp/site"; mkdir -p "$site/assets" "$site/nested/deep"
echo '<h1>hi</h1>'  > "$site/index.html"
echo 'body{}'       > "$site/assets/app.4f3a9c21.css"
echo 'x'            > "$site/assets/plain.css"
echo 'y'            > "$site/assets/chunk-AB12CD34.js"
echo '{}'           > "$site/data.json"
echo 'z'            > "$site/nested/deep/page.html"
echo 'hanzo.ai'     > "$site/CNAME"

# --- the manifest ------------------------------------------------------------
# Keys are RELATIVE to the export root: cloud reconciles keep[rel] against them,
# so a leading ./ or an absolute path would match nothing and the completion
# would prune the entire live site.
t "keys are relative, no leading ./"  "$(plan "$site" | awk -F'\t' 'NR>1&&$1~/^\.?\//{print "ABS"}' | head -1)" ""
t "nested paths keep their subdirs"   "$(plan "$site" | awk -F'\t' '$1=="nested/deep/page.html"{print "yes"}')" "yes"
# CNAME is a GitHub Pages artifact: it means nothing to S3 and would ship a stale
# hostname claim into the bucket.
t "CNAME does not travel"             "$(plan "$site" | awk -F'\t' '$1=="CNAME"{print "leaked"}')" ""
t "file count excludes CNAME"         "$(plan "$site" | head -1 | grep -o 'files=[0-9]*')" "files=6"

# --- content type ------------------------------------------------------------
# The presigned POST carries no Content-Type condition, so what CI sends is what
# the object stores and what the edge serves. Send nothing and a browser
# DOWNLOADS every page instead of rendering it.
t "html"  "$(field "$site" index.html 2)"              "text/html; charset=utf-8"
t "css"   "$(field "$site" assets/plain.css 2)"        "text/css; charset=utf-8"
t "js"    "$(field "$site" assets/chunk-AB12CD34.js 2)" "text/javascript; charset=utf-8"
t "json"  "$(field "$site" data.json 2)"               "application/json; charset=utf-8"

# --- cache control: mirrors cloud apps/sites.CacheControlFor -----------------
# These strings are the SERVER's policy, pinned here so the two cannot drift
# apart silently. If cloud changes CacheControlFor, this is what goes red.
t "html is short-lived, long at the edge" "$(field "$site" index.html 3)"        "public, max-age=60, s-maxage=86400"
t "unfingerprinted asset is an hour"      "$(field "$site" assets/plain.css 3)"  "public, max-age=3600"
# The regression this pins: Go spells the class [.\-_], and transcribing that
# into [[ =~ ]] makes the shell reject it as an invalid character range. The `if`
# then merely evaluates false, so every hashed asset silently lost `immutable`.
t "fingerprinted .hash. is immutable"  "$(field "$site" assets/app.4f3a9c21.css 3)"   "public, max-age=31536000, immutable"
t "fingerprinted -HASH- is immutable"  "$(field "$site" assets/chunk-AB12CD34.js 3)"  "public, max-age=31536000, immutable"

# --- fail closed -------------------------------------------------------------
# reconcilePrefix deletes whatever the manifest omits, so an empty manifest is a
# request to delete the live site. A build that enumerated nothing has failed.
empty="$tmp/empty"; mkdir -p "$empty"
plan "$empty" >/dev/null 2>&1
t "empty export is refused"  "$?"  "1"
only_cname="$tmp/onlycname"; mkdir -p "$only_cname"; echo x > "$only_cname/CNAME"
plan "$only_cname" >/dev/null 2>&1
t "a dir holding only CNAME is empty too"  "$?"  "1"
plan "$tmp/does-not-exist" >/dev/null 2>&1
t "missing export dir is refused"  "$?"  "1"

# --- the credential ----------------------------------------------------------
# Not in PLAN mode (that is the offline seam), but a real run must refuse to
# start rather than enqueue a deployment it cannot complete.
out=$(HANZO_DEPLOY_TOKEN= bash "$SD" a-slug "$site" 2>&1); rc=$?
t "no token: exits non-zero"          "$rc"  "1"
t "no token: says which secret"       "$(printf '%s' "$out" | grep -c HANZO_DEPLOY_TOKEN)"  "1"

# The credential preflight fails OPEN, and this is the case that proves it.
# curl writes 000 to stdout itself when it cannot connect, so an added
# `|| echo 000` made the code `000000` — matching no case, taking the
# hard-fail branch, and reporting an unreachable API as a revoked token.
# Every deploy in the estate would refuse to start during a blip, blaming a
# credential that was fine. Port 1 on loopback is refused without leaving
# the machine, so this stays offline like the rest of the suite.
out=$(HANZO_API=http://127.0.0.1:1 HANZO_DEPLOY_TOKEN=sk-unused bash "$SD" a-slug "$site" 2>&1)
t "unreachable API: warns rather than blaming the token"  "$(printf '%s' "$out" | grep -c 'could not reach')"     "1"
t "unreachable API: claims no revocation"                 "$(printf '%s' "$out" | grep -c 'does not authenticate')" "0"

# A REACHABLE API that refuses the preflight must not stop the deploy either,
# and that is the case that actually froze the Sites plane: /v1/keys is the
# session-scoped key-MANAGEMENT route, so it answers a machine `sk-` key and an
# anonymous caller identically (403 "sign in to manage API keys" — measured
# against the live API). The old preflight read any non-200 as proof of
# revocation and exited, so hanzo.ai and hips died there in ~1s on every run
# with the whole build and every gate green above them.
#
# A local server that answers 403 to everything stands in for that shape, so the
# suite stays offline. Python is already required by nothing else here, so this
# uses a bash TCP responder: one connection, one canned response, then gone.
resp="$tmp/403.sh"
cat > "$resp" <<'EOS'
while :; do
  printf 'HTTP/1.1 403 Forbidden
Content-Length: 2
Connection: close

{}' | nc -l 127.0.0.1 8731 >/dev/null 2>&1 || break
done
EOS
if command -v nc >/dev/null 2>&1; then
  bash "$resp" & responder=$!
  sleep 0.4
  out=$(HANZO_API=http://127.0.0.1:8731 HANZO_DEPLOY_TOKEN=sk-unused bash "$SD" a-slug "$site" 2>&1)
  kill "$responder" 2>/dev/null; wait "$responder" 2>/dev/null
  t "reachable 403: does not claim revocation"  "$(printf '%s' "$out" | grep -c 'does not authenticate')"  "0"
  t "reachable 403: gets past the preflight"    "$(printf '%s' "$out" | grep -c 'did not read as a live key')"  "1"
fi

[ $fail -eq 0 ] && echo "PASS" || echo "FAIL"
exit $fail
