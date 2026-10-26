#!/usr/bin/env bash
# Drives the real .hanzo/review/review.sh against a stub reviewer, to show what a
# status the reviewer CHOSE does versus one that means it never answered.
set -uo pipefail

REVIEW="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; kill "${STUB_PID:-0}" "${KMS_PID:-0}" 2>/dev/null' EXIT

# one commit to review
repo="$WORK/repo"; mkdir -p "$repo"; cd "$repo" || exit 1
git init -q .; git config user.email t@t.t; git config user.name t
echo one > a.txt; git add a.txt; git commit -qm base
BASE=$(git rev-parse HEAD)
echo two >> a.txt; git commit -qam change
HEAD_SHA=$(git rev-parse HEAD)

stub() { # stub <status> [body]
  local status=$1 body=${2:-'{"choices":[{"message":{"content":"{\"verdict\":\"pass\"}"}}]}'}
  python3 - "$status" "$body" <<'PY' &
import sys, http.server
status, body = int(sys.argv[1]), sys.argv[2].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0) or 0))
        self.send_response(status)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8791), H).serve_forever()
PY
  STUB_PID=$!
  sleep 1
}

run() { # run -> prints exit code
  REVIEW_API=http://127.0.0.1:8791 REVIEW_TOKEN=stub REVIEW_MODEL=stub REVIEW_FALLBACKS="" \
    bash "$REVIEW" "$BASE" "$HEAD_SHA" > "$WORK/out" 2>&1
  echo $?
}

fail=0
check() { # check <name> <want-exit> <want-grep>
  local name=$1 want=$2 pat=$3 got
  got=$(run)
  if [ "$got" = "$want" ] && grep -q "$pat" "$WORK/out"; then
    echo "  PASS  $name (exit $got)"
  else
    echo "  FAIL  $name: exit $got want $want; looking for '$pat'"
    sed -n '1,12p' "$WORK/out" | sed 's/^/        /'
    fail=1
  fi
  kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null
}

echo "reviewer ANSWERS (200, verdict pass) -> release continues"
stub 200; check "200 pass" 0 "no attack found"

echo "reviewer CHOOSES a refusal (500) -> release still blocked"
stub 500 '{"error":"boom"}'; check "500 refuses" 1 "cannot judge this change"

echo "reviewer ANSWERS but not with a verdict -> refuses, and says what arrived"
stub 200 '{"choices":[{"message":{"content":"I am unable to review this diff."}},{"finish_reason":"stop"}],"usage":{"completion_tokens":9}}'
check "200 non-verdict" 1 "It opened:"

# A long answer that OPENS like a verdict is the case the head alone cannot read:
# every remedy is consistent with those first 200 characters, and only the end
# says which one it is. The padding is longer than the window on purpose, so the
# reported tail can only have come from the far end of the text.
echo "a long non-verdict -> reports BOTH ends and the size, not just the opening"
pad=$(python3 -c "print('x'*400)")
stub 200 "{\"choices\":[{\"message\":{\"content\":\"{ \\\"verdict\\\": \\\"pass\\\", \\\"summary\\\": \\\"$pad\\\" and then it kept talking UNTERMINATED\"}},{\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":2218}}"
check "long non-verdict names the end" 1 "and ended:"
grep -q 'UNTERMINATED' "$WORK/out" \
  && echo "  PASS  the tail shown is the far end of the answer" \
  || { echo "  FAIL  the tail did not reach the end of the text"; fail=1; }
grep -qE 'chars=[0-9]{3,}' "$WORK/out" \
  && echo "  PASS  the size is reported" \
  || { echo "  FAIL  no chars= in the refusal"; fail=1; }

echo "a nit is recorded and does not block"
stub 200 '{"choices":[{"message":{"content":"{\"verdict\":\"pass\",\"findings\":[{\"tag\":\"Nit\",\"file\":\"a.txt\",\"line\":1,\"what\":\"rename it\",\"why\":\"style\"}]}"}}]}'
check "nit does not block" 0 "no attack found"

echo "an Important defect the second read keeps refuses the change"
stub 200 '{"choices":[{"message":{"content":"{\"verdict\":\"pass\",\"findings\":[{\"tag\":\"Important\",\"file\":\"a.txt\",\"line\":1,\"what\":\"drops the auth check\",\"why\":\"the gate is gone\"}],\"keep\":[0]}"}}]}'
check "important defect blocks" 1 "bug review REFUSED"

echo "high-risk path without a sign-off refuses before anyone is asked"
high="$WORK/high"; rm -rf "$high"; mkdir -p "$high/iam"; cd "$high" || exit 1
git init -q .; git config user.email t@t.t; git config user.name t
echo a > iam/token.go; git add iam/token.go; git commit -qm base
hbase=$(git rev-parse HEAD)
echo b >> iam/token.go; git commit -qam change
hhead=$(git rev-parse HEAD)
if REVIEW_API=http://127.0.0.1:8791 REVIEW_TOKEN=stub REVIEW_MODEL=stub REVIEW_FALLBACKS="" \
    bash "$REVIEW" "$hbase" "$hhead" > "$WORK/out" 2>&1; then
  echo "  FAIL  high-risk unsigned: exit 0, want 1"
  fail=1
elif grep -q "no sign-off" "$WORK/out"; then
  echo "  PASS  high-risk unsigned refuses"
else
  echo "  FAIL  high-risk unsigned did not name the sign-off"
  sed -n '1,12p' "$WORK/out" | sed 's/^/        /'
  fail=1
fi

echo "high-risk path with Testing, Risk, and How to revert is read"
git commit -q --amend -m $'change\n\nTesting: go test\nRisk: high\nHow to revert: git revert\n'
hhead=$(git rev-parse HEAD)
stub 200
if REVIEW_API=http://127.0.0.1:8791 REVIEW_TOKEN=stub REVIEW_MODEL=stub REVIEW_FALLBACKS="" \
    bash "$REVIEW" "$hbase" "$hhead" > "$WORK/out" 2>&1 \
    && grep -q "no attack found" "$WORK/out" && grep -q "tier=high" "$WORK/out"; then
  echo "  PASS  high-risk signed passes"
else
  echo "  FAIL  high-risk signed"
  sed -n '1,20p' "$WORK/out" | sed 's/^/        /'
  fail=1
fi
kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null
cd "$repo" || exit 1

# gate.sh mints the reviewer's identity from KMS. A store that refuses the CI
# credential, or holds no review/IAM_CLIENT_ID for it, is the CI identity's fault
# and not the change's: the gate warns and passes. A reviewer that runs and
# refuses still blocks, through the gate as directly.
GATE="$(dirname "$REVIEW")/gate.sh"
kms() { # kms <login-status> <secret-status>
  python3 - "$1" "$2" <<'PY' &
import sys, json, http.server
login, secret = int(sys.argv[1]), int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def answer(self, status, body):
        b = json.dumps(body).encode()
        self.send_response(status); self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0) or 0))
        self.answer(login, {'accessToken': 'kms'} if login == 200 else {'detail': 'forbidden'})
    def do_GET(self):
        self.answer(secret, {'value': 'review-client'} if secret == 200 else {'detail': 'forbidden'})
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8792), H).serve_forever()
PY
  KMS_PID=$!
  sleep 1
}
gate() { # gate <want-exit> <want-grep> <name> -> runs gate.sh against the stub store
  local want=$1 pat=$2 name=$3 got
  KMS_ENDPOINT=http://127.0.0.1:8792 KMS_CLIENT_ID=ci KMS_CLIENT_SECRET=s IAM_ENDPOINT=http://127.0.0.1:8792 \
    bash "$GATE" "$BASE" "$HEAD_SHA" > "$WORK/out" 2>&1; got=$?
  if [ "$got" = "$want" ] && grep -q "$pat" "$WORK/out"; then
    echo "  PASS  $name (exit $got)"
  else
    echo "  FAIL  $name: exit $got want $want; looking for '$pat'"
    sed -n '1,12p' "$WORK/out" | sed 's/^/        /'
    fail=1
  fi
  kill "$KMS_PID" 2>/dev/null; wait "$KMS_PID" 2>/dev/null
}

echo "the store REFUSES the CI credential (KMS 403) -> warned, release continues (~75s of retries)"
kms 403 403; gate 0 "::warning::review: KMS login.*answered 403.*withholds no verdict" "KMS 403 does not block"

echo "the store holds no review/IAM_CLIENT_ID for this org (403) -> warned, release continues (~75s of retries)"
kms 200 403; gate 0 "::warning::review: the store answered 403 for review/IAM_CLIENT_ID" "IAM_CLIENT_ID 403 does not block"

echo "the IAM endpoint answers its web app, not JSON -> warned at once, release continues"
python3 - <<'PY' &
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0) or 0))
        b = b'<!doctype html><html></html>'
        self.send_response(200); self.send_header('content-type', 'text/html')
        self.send_header('content-length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8793), H).serve_forever()
PY
HTML_PID=$!; sleep 1; kms 200 200
t0=$SECONDS
KMS_ENDPOINT=http://127.0.0.1:8792 KMS_CLIENT_ID=ci KMS_CLIENT_SECRET=s IAM_ENDPOINT=http://127.0.0.1:8793 \
  bash "$GATE" "$BASE" "$HEAD_SHA" > "$WORK/out" 2>&1; got=$?
if [ "$got" = 0 ] && grep -q "does not answer as an IAM token endpoint" "$WORK/out" && [ $((SECONDS - t0)) -lt 20 ]; then
  echo "  PASS  a web app at the IAM address does not block, and is not asked again"
else
  echo "  FAIL  a web app at the IAM address: exit $got in $((SECONDS - t0))s"; sed -n '1,12p' "$WORK/out" | sed 's/^/        /'; fail=1
fi
kill "$KMS_PID" "$HTML_PID" 2>/dev/null; wait "$KMS_PID" "$HTML_PID" 2>/dev/null

echo "a reviewer that runs and REFUSES still blocks through the gate"
stub 500 '{"error":"boom"}'
REVIEW_API=http://127.0.0.1:8791 REVIEW_TOKEN=stub REVIEW_MODEL=stub REVIEW_FALLBACKS="" \
  bash "$GATE" "$BASE" "$HEAD_SHA" > "$WORK/out" 2>&1; got=$?
if [ "$got" = 1 ] && grep -q "cannot judge this change" "$WORK/out"; then
  echo "  PASS  a refusal through the gate blocks (exit 1)"
else
  echo "  FAIL  a refusal through the gate: exit $got want 1"; sed -n '1,12p' "$WORK/out" | sed 's/^/        /'; fail=1
fi
kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null

echo "reviewer NEVER ANSWERS (503) -> recorded, release continues (~150s of retries)"
stub 503 '{"msg":"identity is unavailable"}'; check "503 unreviewed" 0 "UNREVIEWED"

exit $fail
