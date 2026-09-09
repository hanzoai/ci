#!/usr/bin/env bash
# Tests for bin/imgplat, and for the property the script exists to hold: BOTH
# build lanes read back what they published. Runs offline — a stub `crane` on
# PATH answers with manifests taken from real registry replies, so what is tested
# is the parse and the refusal, not the network.
# Run: bash bin/imgplat_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
IMGPLAT="$PWD/bin/imgplat"
WF=".github/workflows/build.yml"
fail=0
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT

# A stub crane: the manifest is whatever MANIFEST names, the config whatever
# CONFIG names. docker must be invisible so the crane branch is the one taken.
cat > "$STUB/crane" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  manifest) cat "$MANIFEST" ;;
  config)   cat "$CONFIG" ;;
esac
EOF
chmod +x "$STUB/crane"
PATH="$STUB:$PATH"

m() { printf '%s' "$1" > "$STUB/m.json"; export MANIFEST="$STUB/m.json"; }
c() { printf '%s' "$1" > "$STUB/c.json"; export CONFIG="$STUB/c.json"; }

t() { # t <name> <want> <args...>
  local name="$1" want="$2"; shift 2
  got=$(bash "$IMGPLAT" "$@" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  [ -z "$got" ] && got="ERROR"
  if [ "$got" = "$want" ]; then printf 'ok    %-56s -> %s\n' "$name" "$got"
  else printf 'FAIL  %-56s -> %s (want %s)\n' "$name" "$got" "$want"; fail=1; fi
}

r() { # r <name> <expect-exit> <args...>
  local name="$1" want="$2"; shift 2
  bash "$IMGPLAT" "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then printf 'ok    %-56s -> exit %s\n' "$name" "$got"
  else printf 'FAIL  %-56s -> exit %s (want %s)\n' "$name" "$got" "$want"; fail=1; fi
}

IDX2='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'
IDX1='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}'
ATT='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"unknown","architecture":"unknown"}}]}'
BARE='{"config":{"digest":"sha256:x"}}'

# --- what an image serves ----------------------------------------------------
m "$IDX2"; t "an index with two manifests serves two"        "linux/amd64 linux/arm64" x:1
m "$IDX1"; t "an index with one manifest serves one"         "linux/amd64"             x:1
m "$ATT";  t "an attestation is not an architecture"         "linux/amd64"             x:1
m "$BARE"; c '{"os":"linux","architecture":"arm64"}'
           t "a bare manifest answers from its config"       "linux/arm64"             x:1

# --- the refusal -------------------------------------------------------------
m "$IDX2"; r "both declared, both served"                0 x:1 linux/amd64,linux/arm64
m "$IDX2"; r "order is not part of the comparison"      0 x:1 linux/arm64,linux/amd64
m "$IDX1"; r "an arch-neutral tag over one platform"    1 x:1 linux/amd64,linux/arm64
m "$IDX2"; r "a second platform nobody declared"        1 x:1 linux/amd64
m "$IDX1"; r "no expectation asserts nothing"           0 x:1

# --- one rule, both lanes ----------------------------------------------------
# The whole point of the script is that neither lane can publish an image it did
# not prove. A lane that stops calling it publishes the same silence that made
# cloud:sha-ac39bda an arch-neutral tag over a single amd64 manifest.
for lane in "Build & push images (per hanzo.yml)" "Delegate build to the runner (mode=delegate)"; do
  s=$(awk -v n="      - name: $lane" 'index($0,n)==1{f=1;next} f&&/^      - name: /{exit} f' "$WF")
  if printf '%s' "$s" | grep -q 'bin/imgplat'; then
    printf 'ok    %-56s -> proves what it published\n' "${lane%% (*}"
  else
    printf 'FAIL  %-56s -> publishes without reading the manifest back\n' "${lane%% (*}"; fail=1
  fi
done

echo
[ $fail -eq 0 ] && echo "imgplat: all cases pass" || echo "imgplat: FAILURES"
exit $fail
