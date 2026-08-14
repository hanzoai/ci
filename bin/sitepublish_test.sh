#!/usr/bin/env bash
# Tests for bin/sitepublish. Runs OFFLINE and deterministically: a `curl` shim on
# PATH answers the three routes from fixtures, so every case here — including the
# ones that must FAIL — needs no token, no bucket and no cluster.
# Run: bash bin/sitepublish_test.sh
#
# The suite is weighted toward REFUSALS on purpose. A publish step that reports
# success when it verified nothing is worse than one that does not verify at all,
# because it is indistinguishable from a working one until a site silently stops
# updating. Three real defects of that exact shape are pinned below by name:
#
#   • an object-shaped read (`.releaseId`) against a body that is not an object
#   • `.releases[]` against the BARE ARRAY /v1/sites/<slug>/releases returns,
#     which resolves nothing and therefore can never fail for its stated reason
#   • `[ "$a" = "$b" ]` on two values that are both empty, which is TRUE
set -uo pipefail
cd "$(dirname "$0")/.."
SP="$PWD/bin/sitepublish"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

t() { # t <name> <want_rc> <got_rc> [<must-contain> <output>]
  local name="$1" want="$2" got="$3" needle="${4:-}" out="${5:-}"
  if [ "$got" != "$want" ]; then
    printf 'FAIL  %-58s rc=%s (want %s)\n' "$name" "$got" "$want"; fail=1; return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    printf 'FAIL  %-58s rc=%s but missing %q\n' "$name" "$got" "$needle"; fail=1
    printf '      got: %s\n' "$(printf '%s' "$out" | head -c 300)"; return
  fi
  printf 'ok    %-58s rc=%s\n' "$name" "$got"
}

# ---- a curl shim -------------------------------------------------------------
# Dispatches on the URL and writes the fixture the scenario names to the file the
# real curl would have written, then prints the status the way `-w %{http_code}`
# does. Everything the script does with a response goes through this, so the
# tests exercise the REAL parsing, not a mock of it.
shim="$tmp/bin"; mkdir -p "$shim"
cat > "$shim/curl" <<'SHIM'
#!/usr/bin/env bash
out=/dev/null url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */deploy)   printf '%s' "${T_DEPLOY_BODY:-{\"ok\":true\}}" > "$out"; printf '%s' "${T_DEPLOY_CODE:-200}" ;;
  */publish)  printf '%s' "${T_PUBLISH_BODY:-}"              > "$out"; printf '%s' "${T_PUBLISH_CODE:-200}" ;;
  */releases) printf '%s' "${T_LIST_BODY:-}"                 > "$out"; printf '%s' "${T_LIST_CODE:-200}" ;;
  *) echo "shim: unexpected url $url" >&2; exit 9 ;;
esac
SHIM
chmod +x "$shim/curl"

site="$tmp/site"; mkdir -p "$site/assets"
echo '<h1>hi</h1>' > "$site/index.html"
echo 'body{}'      > "$site/assets/app.css"
echo 'hanzo.ai'    > "$site/CNAME"

run() { # run <dir> — publish with the shim on PATH, current T_* scenario
  PATH="$shim:$PATH" HANZO_API_TOKEN=tok HANZO_API=https://api.test \
    bash "$SP" a-slug "$1" 2>&1
}
OK_PUB='{"releaseId":"rel-1","slug":"a-slug","objects":2,"active":true,"url":"https://a-slug.hanzo.page"}'
OK_LIST='[{"releaseId":"rel-1","active":true},{"releaseId":"rel-0","active":false}]'

# ---- the plan seam: no network, no token ------------------------------------
out=$(SITEPUBLISH_PLAN=1 bash "$SP" a-slug "$site" 2>&1); rc=$?
t "plan prints the manifest and exits" 0 $rc "files=2" "$out"
# CNAME is a GitHub Pages artifact: it means nothing to S3 and would ship a stale
# hostname claim. Two files, not three.
t "plan excludes CNAME from the count" 0 $rc "files=2 " "$out"
t "plan sends source=<slug>, org-relative" 0 $rc "source=a-slug" "$out"

# ---- refusals that need no network ------------------------------------------
out=$(SITEPUBLISH_PLAN=1 bash "$SP" 'Bad_Slug' "$site" 2>&1); rc=$?
t "an invalid slug is refused before anything" 1 $rc "is not a project slug" "$out"
out=$(SITEPUBLISH_PLAN=1 bash "$SP" a-slug "$tmp/nope" 2>&1); rc=$?
t "a missing export dir is refused" 1 $rc "is not a directory" "$out"
noidx="$tmp/noidx"; mkdir -p "$noidx"; echo x > "$noidx/page.html"
out=$(SITEPUBLISH_PLAN=1 bash "$SP" a-slug "$noidx" 2>&1); rc=$?
t "an export with no index.html is refused" 1 $rc "no index.html at its root" "$out"
empty="$tmp/empty"; mkdir -p "$empty"; echo x > "$empty/index.html"; rm "$empty/index.html"
out=$(SITEPUBLISH_PLAN=1 bash "$SP" a-slug "$empty" 2>&1); rc=$?
t "an empty export is refused" 1 $rc "no index.html" "$out"

# The size refusal is the whole reason this script measures before it sends:
# past the edge BodyLimit fasthttp rejects the POST before any handler runs and
# reports only "Error when parsing request", which names neither size nor cause.
out=$(GATEWAY_BODY_LIMIT=1 PATH="$shim:$PATH" HANZO_API_TOKEN=tok \
      bash "$SP" a-slug "$site" 2>&1); rc=$?
t "a zip past the edge limit is refused here" 1 $rc "publish aborted" "$out"
t "  ...and the refusal names the server's own knob" 1 $rc "GATEWAY_BODY_LIMIT" "$out"
t "  ...and where that knob is defined" 1 $rc "internal/edge/edge.go" "$out"
t "  ...and the opaque answer it replaces" 1 $rc "Error when parsing request" "$out"
t "  ...and bin/sitedeploy, the transport that fits" 1 $rc "bin/sitedeploy" "$out"

# THE OTHER SIDE OF THE BOUNDARY, and it is the half that matters more. This
# check is only ever allowed to turn a failure into a readable one; a publish
# that would have worked must still work, or the fleet learns to route around
# the gate. So the boundary is asserted from BOTH sides against the REAL zip:
# at exactly the limit it publishes, one byte under it refuses. An off-by-one
# in either direction is the difference between a guard and an outage.
( cd "$site" && zip -qXr "$tmp/probe.zip" . -x './CNAME' )
z=$(wc -c < "$tmp/probe.zip" | tr -d ' ')
out=$(GATEWAY_BODY_LIMIT="$z" T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "a zip exactly AT the limit still publishes" 0 $rc "live: rel-1" "$out"
out=$(GATEWAY_BODY_LIMIT="$((z - 1))" T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "one byte past the limit is refused" 1 $rc "publish aborted" "$out"

# The server caps one artifact at 5000 entries; a 5001-file export can never
# become a Release by ANY transport, so saying so here beats a 413 later.
many="$tmp/many"; mkdir -p "$many"; echo x > "$many/index.html"
( cd "$many" && touch f{1..5001} )
out=$(SITEPUBLISH_PLAN=1 bash "$SP" a-slug "$many" 2>&1); rc=$?
t "an export past maxFiles=5000 is refused" 1 $rc "cloud caps one artifact at 5000" "$out"

# ---- the happy path ----------------------------------------------------------
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "publish + verified flip succeeds" 0 $rc "live: rel-1" "$out"
# The size is reported whether or not it is near the limit, so the number that
# explains a refusal is already in the log of every run that did not have one.
t "  ...and the release size is reported, with the limit" 0 $rc "of the 16.0 MiB edge limit" "$out"

# ---- transport failures carry the server's answer ---------------------------
# Each status is a different fix, so the body is printed rather than swallowed.
out=$(T_DEPLOY_CODE=413 T_DEPLOY_BODY='{"error":"artifact exceeds"}' run "$site"); rc=$?
t "a non-2xx upload fails and prints the body" 1 $rc "artifact exceeds" "$out"
out=$(T_PUBLISH_CODE=402 T_PUBLISH_BODY='{"error":"hosting not enabled"}' run "$site"); rc=$?
t "a non-2xx publish fails and prints the body" 1 $rc "hosting not enabled" "$out"
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_CODE=503 T_LIST_BODY='{"error":"storage"}' run "$site"); rc=$?
t "a non-2xx release list fails" 1 $rc "list releases" "$out"

# ---- defect 1: an object-shaped read against a non-object -------------------
# `jq -r '.releaseId // empty'` yields "" for an array, a null, or an error body,
# and every later test on "" passes vacuously. The shape is asserted first.
out=$(T_PUBLISH_BODY='[{"releaseId":"rel-1"}]' T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "publish answering an ARRAY is refused" 1 $rc "not a release object" "$out"
out=$(T_PUBLISH_BODY='{"ok":true}' T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "publish answering no releaseId is refused" 1 $rc "not a release object" "$out"
out=$(T_PUBLISH_BODY='{"releaseId":""}' T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "publish answering an EMPTY releaseId is refused" 1 $rc "not a release object" "$out"
out=$(T_PUBLISH_BODY='not json' T_LIST_BODY="$OK_LIST" run "$site"); rc=$?
t "publish answering non-JSON is refused" 1 $rc "not a release object" "$out"

# ---- defect 2: the list is a BARE ARRAY -------------------------------------
# release.go:518 is `type projectsReleases []projectsRelease`. A `.releases[]`
# filter resolves NOTHING against that, so an assertion built on it can only ever
# refuse — it never once tested what it claimed to. The guard demands the array
# shape, so the day cloud wraps the list THAT is what goes red, by name.
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='{"releases":[{"releaseId":"rel-1","active":true}]}' run "$site"); rc=$?
t "a WRAPPED release list is refused, loudly" 1 $rc "bare-array shape" "$out"
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='[]' run "$site"); rc=$?
t "an EMPTY release list is refused" 1 $rc "non-empty JSON array" "$out"
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='null' run "$site"); rc=$?
t "a null release list is refused" 1 $rc "non-empty JSON array" "$out"

# ---- defect 3: counting, so "none" cannot read as "yes" ---------------------
# A bare `grep '"active":true'` matches ANY release in the list, so it passes
# both when the wrong release is live and when the list merely mentions one.
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='[{"releaseId":"rel-1","active":false}]' run "$site"); rc=$?
t "ZERO active releases is refused" 1 $rc "expected exactly 1 active release" "$out"
out=$(T_PUBLISH_BODY="$OK_PUB" \
      T_LIST_BODY='[{"releaseId":"rel-1","active":true},{"releaseId":"rel-2","active":true}]' run "$site"); rc=$?
t "TWO active releases is refused" 1 $rc "expected exactly 1 active release" "$out"
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='[{"releaseId":"rel-9","active":true}]' run "$site"); rc=$?
t "a DIFFERENT release being live is refused" 1 $rc "the flip did not take" "$out"

# The both-empty comparison, head on: an active entry whose releaseId is "".
# `[ "$active" = "$rid" ]` with both empty is TRUE and would report success on a
# release that does not exist. Non-emptiness is proven before the comparison.
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='[{"releaseId":"","active":true}]' run "$site"); rc=$?
t "an active release with an EMPTY id is refused" 1 $rc "carries no releaseId" "$out"
out=$(T_PUBLISH_BODY="$OK_PUB" T_LIST_BODY='[{"active":true}]' run "$site"); rc=$?
t "an active release with NO id field is refused" 1 $rc "carries no releaseId" "$out"

# ---- the credential is required ---------------------------------------------
out=$(PATH="$shim:$PATH" HANZO_API_TOKEN= bash "$SP" a-slug "$site" 2>&1); rc=$?
t "a missing bearer refuses before any request" 1 $rc "HANZO_API_TOKEN is unset" "$out"

echo
[ "$fail" = 0 ] && echo "sitepublish: all tests passed" || echo "sitepublish: FAILURES"
exit "$fail"
