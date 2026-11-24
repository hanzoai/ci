#!/usr/bin/env bash
# Tests for bin/sourcemaps: which maps go up, at which address, under which
# release, and that every map leaves the export whether or not it went up.
# Offline two ways, like bin/site_test.sh: SOURCEMAPS_PLAN=1 prints each PUT, and
# a `curl` shim on PATH records the real requests and answers from a fixture.
# Run: bash bin/sourcemaps_test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin/sourcemaps"
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
t() { # t <name> <got> <want>
  if [ "$2" = "$3" ]; then printf 'ok    %-58s\n' "$1"
  else printf 'FAIL  %-58s -> %s (want %s)\n' "$1" "$2" "$3"; fail=1; fi
}

# export <dir>: a Vite-shaped build with a map per script and per stylesheet.
mkexport() {
  rm -rf "$1"; mkdir -p "$1/assets/vendor"
  printf 'console.log(1)\n//# sourceMappingURL=index-3f9a.js.map\n' > "$1/assets/index-3f9a.js"
  printf '{"version":3}' > "$1/assets/index-3f9a.js.map"
  printf 'export{}\n//# sourceMappingURL=react-77c1.mjs.map' > "$1/assets/vendor/react-77c1.mjs"
  printf '{"version":3}' > "$1/assets/vendor/react-77c1.mjs.map"
  printf 'body{}\n/*# sourceMappingURL=app-1b2c.css.map */\n' > "$1/assets/app-1b2c.css"
  printf '{"version":3}' > "$1/assets/app-1b2c.css.map"
  printf '{"version":3}' > "$1/assets/orphan.js.map" # its script is not in the export
  printf '<h1>hi</h1>\n' > "$1/index.html"
}
maps_left() { find "$1" -name '*.map' | wc -l | tr -d ' '; }

# --- the plan ---------------------------------------------------------------
E="$T/out"; mkexport "$E"
got=$(SOURCEMAPS_PLAN=1 HANZO_RELEASE=abc123 HANZO_API=https://api.test bash "$BIN" "$E" 2>&1)
puts=$(grep '^PUT ' <<<"$got" | sort)
t "every script map goes up, stylesheets and orphans do not" "$(wc -l <<<"$puts" | tr -d ' ')" 2
t "the address is the served path, under the release" \
  "$(head -1 <<<"$puts")" \
  "PUT https://api.test/v1/event/sourcemaps?release=abc123&file=%2Fassets%2Findex-3f9a.js <- assets/index-3f9a.js.map"
t "a nested script keeps its path" \
  "$(sed -n 2p <<<"$puts" | cut -d' ' -f2)" \
  "https://api.test/v1/event/sourcemaps?release=abc123&file=%2Fassets%2Fvendor%2Freact-77c1.mjs"
t "every map leaves the export" "$(maps_left "$E")" 0
t "the script's map comment is dropped" "$(cat "$E/assets/index-3f9a.js")" "console.log(1)"
t "a comment with no trailing newline is dropped" "$(cat "$E/assets/vendor/react-77c1.mjs")" "export{}"
t "the stylesheet's map comment is dropped" "$(cat "$E/assets/app-1b2c.css")" "body{}"
t "pages are untouched" "$(cat "$E/index.html")" "<h1>hi</h1>"

# A site served below a path is addressed below it.
mkexport "$E"
got=$(SOURCEMAPS_PLAN=1 HANZO_RELEASE=abc123 HANZO_API=https://api.test bash "$BIN" "$E" /post/ 2>&1)
t "a base path prefixes the served path" \
  "$(grep -c 'file=%2Fpost%2Fassets%2Findex-3f9a.js ' <<<"$got")" 1

# No release: nothing goes up, and still nothing is left behind.
mkexport "$E"
got=$(SOURCEMAPS_PLAN=1 HANZO_RELEASE= GITHUB_SHA= bash "$BIN" "$E" 2>&1)
t "no release uploads nothing" "$(grep -c '^PUT ' <<<"$got")" 0
t "no release warns" "$(grep -c '::warning::sourcemaps: no release' <<<"$got")" 1
t "no release still removes every map" "$(maps_left "$E")" 0

# GITHUB_SHA is the release when HANZO_RELEASE is unset.
mkexport "$E"
got=$(env -u HANZO_RELEASE SOURCEMAPS_PLAN=1 GITHUB_SHA=deadbeef bash "$BIN" "$E" 2>&1)
t "GITHUB_SHA stands in for the release" "$(grep -c 'release=deadbeef&' <<<"$got")" 2

# Refusals.
SOURCEMAPS_PLAN=1 bash "$BIN" "$T/nope" >/dev/null 2>&1; t "a missing export is refused" $? 1
SOURCEMAPS_PLAN=1 bash "$BIN" "$E" post >/dev/null 2>&1; t "a base that is not a path is refused" $? 1
mkdir -p "$T/empty"; got=$(SOURCEMAPS_PLAN=1 HANZO_RELEASE=a bash "$BIN" "$T/empty" 2>&1)
t "an export with no maps is a notice" "$(grep -c '::notice::' <<<"$got")" 1

# --- the wire, through a curl shim -----------------------------------------
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
# Records each request; answers the status in $CURL_CODE, writing a body to -o.
out=; prev=
for a in "$@"; do
  [ "$prev" = -o ] && out=$a
  prev=$a
done
printf '%s\n' "$*" >> "$CURL_LOG"
[ -n "$out" ] && printf '{"code":"x"}' > "$out"
printf '%s' "${CURL_CODE:-201}"
SH
chmod +x "$SHIM/curl"

mkexport "$E"; : > "$T/log"
got=$(PATH="$SHIM:$PATH" CURL_LOG="$T/log" CURL_CODE=201 HANZO_API_TOKEN=tok HANZO_RELEASE=abc123 HANZO_API=https://api.test bash "$BIN" "$E" 2>&1)
t "two requests" "$(wc -l < "$T/log" | tr -d ' ')" 2
t "each is a PUT with the run's bearer and the map as the body" \
  "$(grep -c -- '-X PUT -H Authorization: Bearer tok -H Content-Type: application/json --data-binary @' "$T/log")" 2
t "the summary counts them" "$(grep -c 'sourcemaps: 2 uploaded, 0 failed' <<<"$got")" 1

mkexport "$E"; : > "$T/log"
got=$(PATH="$SHIM:$PATH" CURL_LOG="$T/log" CURL_CODE=403 HANZO_API_TOKEN=tok HANZO_RELEASE=abc123 bash "$BIN" "$E" 2>&1)
code=$?
t "a refused upload does not fail the publish" "$code" 0
t "a refused upload warns with its status" "$(grep -c '::warning::sourcemaps: /assets/index-3f9a.js was not uploaded (HTTP 403)' <<<"$got")" 1
t "a refused upload still removes every map" "$(maps_left "$E")" 0

mkexport "$E"; : > "$T/log"
got=$(PATH="$SHIM:$PATH" CURL_LOG="$T/log" HANZO_API_TOKEN= HANZO_RELEASE=abc123 bash "$BIN" "$E" 2>&1)
t "no token sends nothing" "$(wc -l < "$T/log" | tr -d ' ')" 0
t "no token warns" "$(grep -c '::warning::sourcemaps: no HANZO_API_TOKEN' <<<"$got")" 1
t "no token still removes every map" "$(maps_left "$E")" 0

# An inline map cannot be kept private, and the build is told so.
mkexport "$E"; printf 'x\n//# sourceMappingURL=data:application/json;base64,e30=\n' > "$E/assets/inline.js"
got=$(SOURCEMAPS_PLAN=1 HANZO_RELEASE=a bash "$BIN" "$E" 2>&1)
t "an inline map warns" "$(grep -c 'INLINE sourcemaps' <<<"$got")" 1

exit $fail
