#!/usr/bin/env bash
# modsize_test.sh — test suite for bin/modsize
# Follows the pattern of existing bin/*_test.sh suites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh" 2>/dev/null || {
  pass=0; fail=0
  ok()   { pass=$((pass+1)); echo "ok - $1"; }
  nok()  { fail=$((fail+1)); echo "not ok - $1"; }
  plan() { echo "1..$1"; }
  done_testing() { echo "# pass=$pass fail=$fail"; [ "$fail" -eq 0 ]; }
}

plan 7

# --- Test 1: non-repo directory exits 0 ---
tmp=$(mktemp -d)
result=$("$SCRIPT_DIR/modsize" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "non-repo directory exits 0"; else nok "non-repo directory exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 2: missing directory exits 1 ---
result=$("$SCRIPT_DIR/modsize" "/nonexistent/path/xyz" 2>/dev/null; echo $?)
if [ "$result" -eq 1 ]; then ok "missing directory exits 1"; else nok "missing directory exits 1 (got $result)"; fi

# --- Test 3: small Go module exits 0 ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
cat > "$tmp/go.mod" <<'EOF'
module example.com/small

go 1.21
EOF
echo "package main" > "$tmp/main.go"
result=$("$SCRIPT_DIR/modsize" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "small module exits 0"; else nok "small module exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 4: no go.mod exits 0 (not a Go module) ---
tmp=$(mktemp -d)
echo "not a module" > "$tmp/readme.txt"
result=$("$SCRIPT_DIR/modsize" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "no go.mod exits 0"; else nok "no go.mod exits 0 (got $result)"; fi
rm -rf "$tmp"

# --- Test 5: nested modules are all checked ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
cat > "$tmp/go.mod" <<'EOF'
module example.com/parent

go 1.21
EOF
mkdir -p "$tmp/sub"
cat > "$tmp/sub/go.mod" <<'EOF'
module example.com/parent/sub

go 1.21
EOF
result=$("$SCRIPT_DIR/modsize" "$tmp" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "nested modules exit 0 when small"; else nok "nested modules exit 0 when small (got $result)"; fi
rm -rf "$tmp"

# --- Test 6: output reports module size ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
cat > "$tmp/go.mod" <<'EOF'
module example.com/small

go 1.21
EOF
output=$("$SCRIPT_DIR/modsize" "$tmp" 2>&1)
if echo "$output" | grep -qiE "(size|bytes|kb|mb|mib|module)"; then ok "output reports size info"; else nok "output reports size info"; fi
rm -rf "$tmp"

# --- Test 7: no argument defaults to current directory ---
tmp=$(mktemp -d)
git -C "$tmp" init -q 2>/dev/null
cat > "$tmp/go.mod" <<'EOF'
module example.com/small

go 1.21
EOF
result=$(cd "$tmp" && "$SCRIPT_DIR/modsize" 2>/dev/null; echo $?)
if [ "$result" -eq 0 ]; then ok "no argument defaults to cwd"; else nok "no argument defaults to cwd (got $result)"; fi
rm -rf "$tmp"

done_testing
