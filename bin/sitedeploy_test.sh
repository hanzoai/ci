#!/usr/bin/env bash
# Tests for bin/sitedeploy. Runs OFFLINE two ways: SITEDEPLOY_PLAN=1 stops the
# script before the first network call and prints the manifest it would upload,
# and a `curl` shim on PATH records every request and answers it from a fixture.
# So every case here is deterministic and needs no token, no bucket and no
# cluster. Run: bash bin/sitedeploy_test.sh
#
# THE ADDRESSES ARE THE POINT of the shim half. They were described in a comment
# and asserted nowhere, and when cloud split the deploy route in two — /deploy
# became the archive upload alone, reading any body as BYTES — this script went
# on sending its JSON enqueue there. Every static site in the estate stopped
# publishing at once, each build green to the last step, and the whole suite
# stayed PASS throughout. A wire nobody asserts is a wire that moves.
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
# What the object stores, and the fallback the serving path uses for a key whose
# extension it does not recognise. An object stored as application/octet-stream
# is one a browser DOWNLOADS instead of rendering.
t "html"  "$(field "$site" index.html 2)"              "text/html; charset=utf-8"
t "css"   "$(field "$site" assets/plain.css 2)"        "text/css; charset=utf-8"
t "js"    "$(field "$site" assets/chunk-AB12CD34.js 2)" "text/javascript; charset=utf-8"
t "json"  "$(field "$site" data.json 2)"               "application/json; charset=utf-8"

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

# --- the wire ----------------------------------------------------------------
# A curl shim that RECORDS every request and answers it from a fixture, so the
# three addresses, the two bodies and the fields on a per-object POST are all
# asserted rather than described. The shim refuses an address it does not know,
# which is what turns a moved route into a red test instead of a live outage.
shim="$tmp/bin"; mkdir -p "$shim"
cat > "$shim/curl" <<'SHIM'
#!/usr/bin/env bash
out=/dev/null url= method=GET body= src= fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    # The FILE, not its contents. `$(cat f)` strips trailing newlines, and the
    # completion body is the one request whose exact byte COUNT is asserted —
    # recording it through a command substitution made the record a byte shorter
    # than the thing sent, which is precisely the error a size test cannot carry.
    --data-binary) src="${2#@}"; shift 2 ;;
    -F) fields+=("$2"); shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$T_DIR/calls"
case "$url" in
  # /complete before /deployments: the completion address ends in the collection
  # it belongs to, so the looser pattern would swallow it.
  */complete)      if [ -n "$src" ]; then cp "$src" "$T_DIR/complete.body"
                   else printf '%s' "$body" > "$T_DIR/complete.body"; fi
                   printf '%s' "$T_DONE" > "$out"; printf '200' ;;
  */deployments)   printf '%s' "$body" > "$T_DIR/enqueue.body";  printf '%s' "$T_ENQ"  > "$out"; printf '202' ;;
  */v1/keys)       printf '200' ;;
  # Counted, and 503 for the first T_5XX calls, so a retry can be OBSERVED
  # rather than inferred. T_5XX is unset for every case above, which leaves this
  # a plain 200.
  */v1/projects)   n=$(cat "$T_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$T_DIR/n"
                   printf '{}' > "$out"
                   if [ "$n" -le "${T_5XX:-0}" ]; then printf '503'; else printf '200'; fi ;;
  https://s3.test/*) printf '%s\n' "$(IFS='|'; printf '%s' "${fields[*]}")" >> "$T_DIR/uploads" ;;
  *) echo "shim: unexpected url $url" >&2; exit 9 ;;
esac
SHIM
chmod +x "$shim/curl"

ENQ='{"id":"dep_x","version":7,"status":"queued","bucket":"hanzo-sites","prefix":"acme/a-slug",
      "upload":{"url":"https://s3.test/hanzo-sites","prefix":"acme/a-slug",
                "fields":{"key":"acme/a-slug/","policy":"POLICY","x-amz-signature":"SIG"}}}'
DONE='{"status":"live","liveUrl":"https://a-slug.hanzo.app","version":7,"files":6,"bytes":42}'
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 SITEDEPLOY_COMMIT=abc123 SITEDEPLOY_REPO= \
      T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" bash "$SD" a-slug "$site" 2>&1); rc=$?
calls="$tmp/calls"
t "a full deploy succeeds"  "$rc"  "0"

# THE regression: the enqueue opens a deployment where deployments are created.
t "enqueue POSTs the deployments collection" \
  "$(grep -c '^POST https://api.test/v1/projects/a-slug/deployments$' "$calls")"  "1"
t "nothing JSON is sent to the archive address" \
  "$(grep -c '/v1/projects/a-slug/deploy$' "$calls")"  "0"
t "the completion names the deployment" \
  "$(grep -c '^POST https://api.test/v1/projects/a-slug/deployments/dep_x/complete$' "$calls")"  "1"

# `commit` is the whole enqueue body. `source` was the Content-Type discriminator
# the split removed and `branch` is discarded server-side; a field the server
# does not read is one this script must not claim to send.
t "the enqueue body is commit and nothing else" \
  "$(jq -r 'keys|join(",")' "$tmp/enqueue.body")"  "commit"
t "the commit travels"  "$(jq -r .commit "$tmp/enqueue.body")"  "abc123"

# The completion carries the manifest cloud prunes against, so a short one
# deletes live pages. It is the same six keys the plan enumerated.
t "the completion reports live"        "$(jq -r .status "$tmp/complete.body")"        "live"
t "the completion carries every key"   "$(jq -r '.keys|length' "$tmp/complete.body")" "6"
t "the manifest is relative"           "$(jq -r '.keys|index("nested/deep/page.html")|type' "$tmp/complete.body")" "number"
t "the completion counts the files"    "$(jq -r .files "$tmp/complete.body")"         "6"

# One object POST per file, each carrying the grant verbatim EXCEPT `key`: the
# grant's key is the starts-with placeholder, and forwarding it alongside the
# real one posts `key` twice, which S3 answers 400 for every object — the whole
# of the first end-to-end run, 8403 files and 8403 400s.
t "one upload per file"  "$(wc -l < "$tmp/uploads" | tr -d ' ')"  "6"
t "the real key is sent, once" \
  "$(grep -c 'key=acme/a-slug/index\.html' "$tmp/uploads")"  "1"
t "the placeholder key is dropped" \
  "$(grep -c 'key=acme/a-slug/|' "$tmp/uploads")"  "0"
t "the signed fields travel untouched" \
  "$(grep -c 'policy=POLICY' "$tmp/uploads")"  "6"
# S3 ignores every field after the file part, so a grant field trailing the body
# is silently dropped and the signature check fails.
t "file goes last"  "$(grep -c 'file=@[^|]*$' "$tmp/uploads")"  "6"
# The cache policy is the server's: it composes CacheControlFor on every request
# and does not read the stored header, so a copy of that rule sent from here
# reaches no reader and is free to drift.
t "no cache policy is stamped from here"  "$(grep -c 'Cache-Control=' "$tmp/uploads")"  "0"

# --- the edge body limit ------------------------------------------------------
# The completion manifest is the ONE body this lane still posts through
# api.hanzo.ai, and it grows with the object count. Cloud caps nothing on that
# route — apps/projects/deploy.go:388 declares `Keys []string` with no length
# check — so the only bound is the edge's 16 MiB BodyLimit, and past it fasthttp
# refuses the POST before any handler runs and answers only "Error when parsing
# request", which names neither size nor cause.
#
# Reaching that as a 400 would be the expensive way to learn it: it is the LAST
# of the three calls, so every object is already in the bucket and the deployment
# is already open. Hence measured before the enqueue, and what these cases pin is
# not only that it fires but that it fires having sent nothing.
t "the release size is reported, with the limit" \
  "$(printf '%s' "$out" | grep -c 'of the 16.0 MiB edge limit')"  "1"

# The REAL body the happy path just sent, so the boundary below is measured
# against the thing itself rather than against an estimate of it.
exact=$(wc -c < "$tmp/complete.body" | tr -d ' ')

rm -f "$tmp/calls" "$tmp/complete.body"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 SITEDEPLOY_COMMIT=abc123 T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" \
      GATEWAY_BODY_LIMIT=1 bash "$SD" a-slug "$site" 2>&1); rc=$?
t "a manifest past the edge limit refuses"   "$rc"  "1"
t "  ...naming the server's own knob"        "$(printf '%s' "$out" | grep -c GATEWAY_BODY_LIMIT)"           "1"
t "  ...and where that knob is defined"      "$(printf '%s' "$out" | grep -c 'internal/edge/edge.go')"      "1"
t "  ...and the opaque answer it replaces"   "$(printf '%s' "$out" | grep -c 'Error when parsing request')" "1"
t "  ...and what to do about it"             "$(printf '%s' "$out" | grep -c 'Reduce the object count')"    "1"
# The whole reason it is measured first. A check that fires after the bytes have
# moved is a slower route to the same outage, and it leaves a deployment open.
t "  ...having sent nothing at all"          "$(cat "$tmp/calls" 2>/dev/null | wc -l | tr -d ' ')"  "0"

# THE OTHER SIDE OF THE BOUNDARY, and the half that matters more: this check is
# only ever allowed to turn a failure into a readable one. A publish that would
# have worked must still work, or the fleet learns to route around the gate.
rm -f "$tmp/calls"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 SITEDEPLOY_COMMIT=abc123 T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" \
      GATEWAY_BODY_LIMIT="$exact" bash "$SD" a-slug "$site" 2>&1); rc=$?
t "a manifest exactly AT the limit publishes"  "$rc"  "0"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 SITEDEPLOY_COMMIT=abc123 T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" \
      GATEWAY_BODY_LIMIT="$((exact - 1))" bash "$SD" a-slug "$site" 2>&1); rc=$?
t "one byte past the limit refuses"            "$rc"  "1"

# The shape this was written about: a full prerender multiplied one site's object
# count until every push failed. That export is 627 objects, and on THIS lane it
# publishes — the bytes stream per file and the manifest for 627 keys is
# kilobytes, nowhere near 16 MiB. A guard that refused this would be worse than
# the failure it replaced.
wide="$tmp/wide"; mkdir -p "$wide"
i=0; while [ $i -lt 627 ]; do : > "$wide/page$i.html"; i=$((i + 1)); done
rm -f "$tmp/calls"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=8 T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" \
      bash "$SD" a-slug "$wide" 2>&1); rc=$?
t "a 627-object export publishes"         "$rc"  "0"
t "  ...with every key in the manifest"   "$(jq -r '.keys|length' "$tmp/complete.body")"  "627"

# A deploy that cannot upload must leave cloud an honest terminal state rather
# than a deployment queued forever behind a build that is gone.
rm -f "$tmp/calls" "$tmp/complete.body"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 T_DIR="$tmp" T_ENQ="${ENQ/https:\/\/s3.test/https:\/\/s3.unknown}" T_DONE="$DONE" \
      bash "$SD" a-slug "$site" 2>&1); rc=$?
# Non-zero, not a number: the upload loop is xargs, and a failed child is exit
# 123 on GNU and exit 1 on BSD. Pinning either one passes on the machine it was
# written on and reds on the other.
t "a failed upload fails the deploy"     "$([ "$rc" != 0 ] && echo failed)"  "failed"
t "a failed upload is reported as error" "$(jq -r .status "$tmp/complete.body" 2>/dev/null)"  "error"

# --- 5xx is asked again, 4xx is not ------------------------------------------
# The Sites plane answers 5xx intermittently and a publish that died on one threw
# away a green build: hanzo.ai alternated failed/published/failed across one hour
# on `ensure project ... 503`, with sign and insights flapping beside it. What
# has to hold is the DISTINCTION — a 503 is "not now" and is worth repeating, a
# 403 is "no" and repeating it just spends four sleeps to print the same refusal.
#
# This shim counts calls to /v1/projects and answers 503 for the first two, so a
# pass proves the retry ran rather than that the first call happened to work.
rm -f "$tmp/calls" "$tmp/n"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 SITEDEPLOY_COMMIT=abc123 SITEDEPLOY_REPO= \
      T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" T_5XX=2 bash "$SD" a-slug "$site" 2>&1); rc=$?
t "two 503s do not lose the build"      "$rc"  "0"
t "the 503s were retried, not ignored"  "$(cat "$tmp/n")"  "3"

# The other half. Without it "retry on 5xx" and "retry on anything" both pass,
# and the second spends four sleeps before printing a refusal it had at once.
rm -f "$tmp/calls" "$tmp/n"
out=$(PATH="$shim:$PATH" HANZO_API=https://api.test HANZO_DEPLOY_TOKEN=sk-test \
      SITEDEPLOY_JOBS=1 T_DIR="$tmp" T_ENQ="$ENQ" T_DONE="$DONE" T_5XX=9 \
      bash "$SD" a-slug "$site" 2>&1); rc=$?
t "a plane that never recovers fails"   "$([ "$rc" != 0 ] && echo failed)"  "failed"
t "it gives up rather than hammering"   "$(cat "$tmp/n")"  "5"

[ $fail -eq 0 ] && echo "PASS" || echo "FAIL"
exit $fail
