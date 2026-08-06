#!/usr/bin/env bash
# Tests for bin/publishable. Offline and deterministic: every case is a
# hanzo.yml written into a temp dir. Run: bash bin/publishable_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PUB="$PWD/bin/publishable"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# t <name> <want-rc> <build_secrets yaml-inline list>
t() {
  local name=$1 want=$2 list=$3
  local d="$tmp/$RANDOM$RANDOM"; mkdir -p "$d"
  { echo 'images:'; echo '  - name: app'; echo '    repo: ghcr.io/hanzoai/app'
    [ -n "$list" ] && echo "    build_secrets: $list"; } > "$d/hanzo.yml"
  out=$(bash "$PUB" "$d/hanzo.yml" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then printf 'ok    %-56s rc=%s\n' "$name" "$rc"
  else printf 'FAIL  %-56s rc=%s (want %s)\n      %s\n' "$name" "$rc" "$want" "$out"; fail=1; fi
}

echo "--- refused: a name that never claimed to be public ---"
# The live case. hanzoai/ui declares exactly this, and its value IS publishable
# — but nothing outside its own Dockerfile could know that.
t "EVENT_INGEST_KEY is refused"              1 '[EVENT_INGEST_KEY]'
t "a real credential is refused"             1 '[STRIPE_SECRET_KEY]'
t "a token is refused"                       1 '[GITHUB_TOKEN]'
t "a password is refused"                    1 '[DB_PASSWORD]'
t "a private key is refused"                 1 '[SIGNING_PRIVATE_KEY]'
t "one bad name among good ones is refused"  1 '[VITE_GTM_ID, EVENT_INGEST_KEY]'

echo "--- allowed: the name declares it ---"
# These are the fleet's real declarations, verbatim.
t "PUBLISHABLE_KEY (hanzoai/docs)"           0 '[PUBLISHABLE_KEY]'
t "VITE_MAPBOX_TOKEN (hanzoai/world)"        0 '[VITE_MAPBOX_TOKEN]'
t "VITE_SENTRY_DSN (hanzoai/world)"          0 '[VITE_SENTRY_DSN]'
t "world's four together"                    0 '[VITE_MAPBOX_TOKEN, VITE_SENTRY_DSN, VITE_ANALYTICS_WEBSITE_ID, VITE_GTM_ID]'
t "NEXT_PUBLIC_ prefix"                      0 '[NEXT_PUBLIC_INGEST_KEY]'
t "REACT_APP_ prefix"                        0 '[REACT_APP_MAP_KEY]'
t "EXPO_PUBLIC_ prefix"                      0 '[EXPO_PUBLIC_API_KEY]'
t "NUXT_PUBLIC_ prefix"                      0 '[NUXT_PUBLIC_API_KEY]'
t "PUBLIC_ prefix"                           0 '[PUBLIC_ANALYTICS_ID]'
t "_PUBLISHABLE suffix"                      0 '[STRIPE_PUBLISHABLE]'
t "_PUBLIC suffix"                           0 '[ANALYTICS_ID_PUBLIC]'

echo "--- silent: nothing declared, nothing to say ---"
# 44 of the fleet's 47 repos are this case and must be byte-for-byte unchanged.
t "no build_secrets key at all"              0 ''
t "empty build_secrets list"                 0 '[]'

echo "--- a missing file is not a refusal ---"
out=$(bash "$PUB" "$tmp/does-not-exist.yml" 2>&1); rc=$?
if [ "$rc" = 0 ]; then printf 'ok    %-56s rc=0\n' "absent hanzo.yml is silent"
else printf 'FAIL  %-56s rc=%s\n' "absent hanzo.yml is silent" "$rc"; fail=1; fi

echo "--- the refusal says what to do about it ---"
d="$tmp/msg"; mkdir -p "$d"
printf 'images:\n  - name: app\n    build_secrets: [EVENT_INGEST_KEY]\n' > "$d/hanzo.yml"
out=$(bash "$PUB" "$d/hanzo.yml" 2>&1)
for pat in "EVENT_INGEST_KEY" "docker history" "PUBLISHABLE_" "cannot be a build_secret"; do
  if printf '%s' "$out" | grep -qF "$pat"; then printf 'ok    %-56s\n' "message names '$pat'"
  else printf 'FAIL  %-56s\n      got: %s\n' "message names '$pat'" "$out"; fail=1; fi
done

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit $fail
