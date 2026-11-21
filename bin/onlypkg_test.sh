#!/usr/bin/env bash
# Tests for `onlypkg`, which lets a tag naming one package skip the client
# check, because that package does not carry the generated client. There is no
# bin/onlypkg: the function lives in .github/workflows/build.yml, and this suite
# lifts it out and runs that text.
#
# The case it exists for: python-sdk's `hanzo-tools-fs-v0.3.5` publishes one
# wheel built from pkg/hanzo-tools-fs, and the publish job refused it because
# pkg/hanzoai/cloud had drifted from production (hanzo-inc/cloud#758). The
# refusal it must keep: a `v*` tag, the client's own package tag and a branch
# push still refuse a drifted client.
#
# Two halves. The first asks `onlypkg` about tags. The second runs the whole
# client step, as the runner would, over a projection whose generator reports
# drift: the network fetch and the driver clone are stubbed, nothing else is.
#
# Offline. Needs yq and jq, which the pipeline provisions. Run: bash bin/onlypkg_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=$PWD/.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

for t in yq jq; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "FAIL  $t is not on PATH — the client step runs under it, and a suite that cannot run must not read as passed"; exit 1; }
done

sed -n '/^          # onlypkg BEGIN$/,/^          # onlypkg END$/p' "$DEF" | sed 's/^          //' > "$tmp/onlypkg.sh"
grep -q '^onlypkg() {' "$tmp/onlypkg.sh" || {
  echo "FAIL  could not lift onlypkg() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }

# ONE READING OF A TAG. The PyPI lane decides what a tag publishes and onlypkg
# decides what it skips, so they must strip a tag to a name the same way.
n=$(grep -cF "sed -E 's/[-@]v?[0-9].*\$//'" "$DEF")
if [ "$n" = 2 ]; then echo "ok   the PyPI lane and onlypkg read a tag with one expression"; else
  echo "FAIL the tag-to-name expression appears $n time(s) in $DEF, want 2 (PyPI lane + onlypkg) — they read tags differently"; fail=1; fi

# tree <dir> <client.version>: python-sdk's shape. The root is the client
# (`hanzoai`), pkg/* are distributions of their own.
tree() {
  local r=$1 cv=$2
  mkdir -p "$r/pkg/hanzo-tools-fs" "$r/pkg/hanzo-mcp" "$r/pkg/notapackage"
  printf '[project]\nname = "hanzoai"\nversion = "8.5.1188"\n' > "$r/pyproject.toml"
  printf '[project]\nname = "hanzo-tools-fs"\nversion = "0.3.5"\n' > "$r/pkg/hanzo-tools-fs/pyproject.toml"
  printf '[project]\nname = "hanzo-mcp"\nversion = "1.0.0"\n' > "$r/pkg/hanzo-mcp/pyproject.toml"
  printf 'pypi: [., pkg/*]\nclient:\n  generate: ./gen.sh\n' > "$r/hanzo.yml"
  [ -z "$cv" ] || CV=$cv yq -i '.client.version = strenv(CV)' "$r/hanzo.yml"
}

# python-sdk's own client.version, verbatim.
PYVER="pyproject.toml:grep -m1 '^version' pyproject.toml | sed -E 's/.*\"(.*)\".*/\\1/'"
tree "$tmp/sdk" "$PYVER"
tree "$tmp/noversion" ""
tree "$tmp/inpkg" "pkg/hanzo-tools-fs/pyproject.toml:grep -m1 '^version' pkg/hanzo-tools-fs/pyproject.toml"
mkdir -p "$tmp/nopypi"; printf 'client:\n  generate: ./gen.sh\n' > "$tmp/nopypi/hanzo.yml"

# ask <name> <tree> <ref type> <ref name> <want output>
ask() {
  local name=$1 dir=$2 type=$3 ref=$4 want=$5 got rc
  got=$(cd "$dir" && bash -c 'set -euo pipefail; . "$1"; onlypkg "$2" "$3"' _ "$tmp/onlypkg.sh" "$type" "$ref" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then echo "ok   $name"; else
    echo "FAIL $name: want rc=0 and [${want}], got rc=$rc [${got}]"; fail=1; fi
}

ask "hanzo-tools-fs-v0.3.5 publishes pkg/hanzo-tools-fs alone"   "$tmp/sdk" tag hanzo-tools-fs-v0.3.5 "pkg/hanzo-tools-fs"
ask "hanzo-tools-fs@v0.3.5, the @ shape, is the same release"     "$tmp/sdk" tag hanzo-tools-fs@v0.3.5 "pkg/hanzo-tools-fs"
ask "hanzo-tools-fs-0.3.5, with no v, is the same release"        "$tmp/sdk" tag hanzo-tools-fs-0.3.5  "pkg/hanzo-tools-fs"
ask "hanzo-mcp-v1.0.0 publishes pkg/hanzo-mcp alone"              "$tmp/sdk" tag hanzo-mcp-v1.0.0      "pkg/hanzo-mcp"
ask "a v* tag publishes everything, the client too: check"        "$tmp/sdk" tag v8.5.1312             ""
ask "the client's own tag (hanzoai-v*) publishes it: check"       "$tmp/sdk" tag hanzoai-v8.5.1312     ""
ask "a tag naming no declared project selects nothing: check"     "$tmp/sdk" tag hanzo-nope-v1.0.0     ""
ask "a tag with no version on its end releases nothing: check"    "$tmp/sdk" tag hanzo-tools-fs        ""
ask "a branch push: check"                                        "$tmp/sdk" branch main               ""
ask "no ref type at all: check"                                   "$tmp/sdk" "" hanzo-tools-fs-v0.3.5  ""
ask "a tag type with an empty name: check"                        "$tmp/sdk" tag ""                    ""
ask "no client.version: the root is the client, pkg/* is not"     "$tmp/noversion" tag hanzo-tools-fs-v0.3.5 "pkg/hanzo-tools-fs"
ask "no client.version: hanzoai-v* is still the client: check"    "$tmp/noversion" tag hanzoai-v8.5.1312     ""
ask "client.version in pkg/hanzo-tools-fs makes it the client"    "$tmp/inpkg" tag hanzo-tools-fs-v0.3.5    ""
ask "...and then the root package is the one skipped"             "$tmp/inpkg" tag hanzoai-v8.5.1312        "."
ask "no pypi: declared: nothing is selected, check"               "$tmp/nopypi" tag hanzo-tools-fs-v0.3.5  ""

# THE WHOLE STEP, over a drifted projection. Lift the client step's `run:` body
# out of the file the runner reads and run it with the step's own environment.
awk '/^      - name: Client — regenerate from the release document \(per hanzo.yml\)$/{on=1; next}
     on && /^      - name: /{exit}
     on && f {print}
     on && /^        run: \|$/{f=1}' "$DEF" | sed 's/^          //' > "$tmp/step.sh"
grep -q 'onlypkg "${REF_TYPE:-}" "${REF_NAME:-}"' "$tmp/step.sh" || {
  echo "FAIL  could not lift the client step's run: body out of $DEF, or it no longer asks onlypkg — fix this suite"; exit 1; }

# Stubs for the two network reads, each logging that it ran. A skipped check
# must not need the network at all.
mkdir -p "$tmp/stub"
cat > "$tmp/stub/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = -o ] && { printf '{"openapi":"3.1.0"}\n' > "$2"; shift; }; shift; done
SH
printf '#!/usr/bin/env bash\necho "uv $*" >> "$CALLS"\n' > "$tmp/stub/uv"
chmod +x "$tmp/stub/curl" "$tmp/stub/uv"

# The generator, as python-sdk's scripts/generate.sh answers on drift.
cat > "$tmp/sdk/gen.sh" <<'SH'
#!/usr/bin/env bash
echo "gen $*" >> "$CALLS"
if [ -f .drifted ]; then echo "pkg/hanzoai/cloud DRIFTED: +48 -1 ~37" >&2; exit 1; fi
echo "pkg/hanzoai/cloud matches the document"
SH
chmod +x "$tmp/sdk/gen.sh"
printf 'ref=33ad9af4f14246d67ff29e0d1379288f6b727d59\nsha256=00\nrepo=hanzo-inc/cloud\npath=openapi.yaml\n' > "$tmp/sdk/.spec-lock"

# run <name> <ref type> <ref name> <drifted 0|1> <want rc: 0|refuses> <want in output> <generator runs: yes|no>
run() {
  local name=$1 type=$2 ref=$3 drifted=$4 want=$5 match=$6 gen=$7 rt out rc ok=1
  rt=$(mktemp -d "$tmp/rt.XXXX"); mkdir -p "$rt/driver"
  : > "$rt/calls"; : > "$rt/output"; : > "$rt/summary"
  if [ "$drifted" = 1 ]; then : > "$tmp/sdk/.drifted"; else rm -f "$tmp/sdk/.drifted"; fi
  out=$(cd "$tmp/sdk" && env -i PATH="$tmp/stub:$PATH" HOME="$rt" CALLS="$rt/calls" \
        RUNNER_TEMP="$rt" GITHUB_OUTPUT="$rt/output" GITHUB_STEP_SUMMARY="$rt/summary" GITHUB_PATH="$rt/path" \
        PAYLOAD=null SPEC_REF= SPEC_VERSION_IN= SPEC_SHA256= REF_TYPE="$type" REF_NAME="$ref" \
        bash "$tmp/step.sh" 2>&1); rc=$?
  out="$out$(cat "$rt/summary")"
  if [ "$want" = refuses ]; then [ "$rc" != 0 ] || ok=0; else [ "$rc" = "$want" ] || ok=0; fi
  grep -q -- "$match" <<<"$out" || ok=0
  if [ "$gen" = yes ]; then grep -q '^gen --check$' "$rt/calls" || ok=0
  else [ ! -s "$rt/calls" ] || ok=0; grep -qx 'ran=0' "$rt/output" || ok=0; fi
  if [ "$ok" = 1 ]; then echo "ok   $name"; else
    echo "FAIL $name: want rc=$want, [$match], generator runs=$gen; got rc=$rc"
    sed 's/^/       /' <<<"$out"; sed 's/^/       call: /' "$rt/calls"; fail=1; fi
}

run "step: hanzo-tools-fs-v0.3.5 over a drifted client publishes, no generator, no network" \
    tag hanzo-tools-fs-v0.3.5 1 0 "client check skipped: tag hanzo-tools-fs-v0.3.5 publishes pkg/hanzo-tools-fs only" no
run "step: a v* projection tag over a drifted client refuses"   tag v8.5.1312         1 refuses "DRIFTED" yes
run "step: hanzoai-v* over a drifted client refuses"            tag hanzoai-v8.5.1312 1 refuses "DRIFTED" yes
run "step: a branch push over a drifted client refuses"         branch main           1 refuses "DRIFTED" yes
run "step: a v* tag over a client that matches passes the check" tag v8.5.1312        0 0 "matches the document" yes

exit $fail
