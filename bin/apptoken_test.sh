#!/usr/bin/env bash
# Tests for bin/apptoken. Offline: a stub curl answers KMS and GitHub from a
# table, writes every request it saw to a log, and a real RSA key signs a real JWT
# that this suite then verifies with the public half. Run: bash bin/apptoken_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
APPTOKEN="$PWD/bin/apptoken"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { # check <name> <condition exit status>
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi
}

openssl genrsa -out "$tmp/app.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/app.pem" -pubout -out "$tmp/app.pub" 2>/dev/null

# The stub. A request is "METHOD URL"; the answer is the first matching line of
# $ROUTES, "<METHOD> <url-substring> <status> <body-file>". It writes the request,
# the Authorization header file's contents and any body to $LOG, and honours
# -o <file> and -w '%{http_code}' the way bin/kms and bin/apptoken use them.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url="" method=GET body="" hdrs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -X) method=$2; shift ;;
    -H) hdrs+=("$2"); shift ;;
    -d|--data-binary) body=$2; method=POST; shift ;;
    -w|-m) shift ;;
    -sS|-s|-S) ;;
    http*) url=$1 ;;
  esac
  shift
done
{
  echo "REQ $method $url"
  for h in ${hdrs[@]+"${hdrs[@]}"}; do
    case "$h" in @*) cat "${h#@}" ;; *) echo "$h" ;; esac
  done
  case "$body" in @*) cat "${body#@}"; echo ;; ?*) echo "$body" ;; esac
} >> "$LOG"
while read -r m u code file; do
  [ "$m" = "$method" ] || continue
  case "$url" in *"$u"*) [ -n "$out" ] && cat "$file" > "$out"; printf '%s' "$code"; exit 0 ;; esac
done < "$ROUTES"
[ -n "$out" ] && : > "$out"
printf '404'
STUB
chmod +x "$tmp/bin/curl"

reply() { printf '%s' "$2" > "$tmp/$1"; }
reply kms_id    '{"value":"1164624"}'
jq -nc --rawfile k "$tmp/app.pem" '{value:$k}' > "$tmp/kms_key"
jq -nc --rawfile k "$tmp/app.pem" '{value:($k | gsub("\n"; "\\n"))}' > "$tmp/kms_key_oneline"
reply inst      '{"id":143007410}'
reply minted    '{"token":"ghs_FAKE_INSTALLATION_TOKEN","permissions":{"contents":"read"}}'
reply denied    '{"message":"Resource not accessible by integration"}'
reply notfound  '{"message":"Not Found"}'

routes() { # routes <key file> <installation status> <mint status> <installation file> <mint file>
  cat > "$tmp/routes" <<EOF
GET /v1/kms/secrets/platform/GITHUB_APP_ID 200 $tmp/kms_id
GET /v1/kms/secrets/platform/GITHUB_APP_PRIVATE_KEY 200 $1
GET /installation $2 $4
POST /access_tokens $3 $5
EOF
}

# run <args...> -> stdout in $tmp/out, stderr in $tmp/err, status in $rc
run() {
  : > "$tmp/log"
  PATH="$tmp/bin:$PATH" LOG="$tmp/log" ROUTES="$tmp/routes" HANZO_API_TOKEN=iam-token \
    bash "$APPTOKEN" "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
}

# 1. One repository, write: the token and nothing else on stdout.
routes "$tmp/kms_key" 200 201 "$tmp/inst" "$tmp/minted"
run hanzoai '{"contents":"write"}' cloud
[ "$rc" = 0 ] && [ "$(cat "$tmp/out")" = "ghs_FAKE_INSTALLATION_TOKEN" ]; check "stdout is the token and nothing else" $?
grep -q '::add-mask::ghs_FAKE_INSTALLATION_TOKEN' "$tmp/err"; check "the token is masked on stderr before anything uses it" $?
grep -q 'REQ GET https://api.github.com/repos/hanzoai/cloud/installation' "$tmp/log"; check "a named repository resolves its installation by repository" $?
grep -q 'REQ POST https://api.github.com/app/installations/143007410/access_tokens' "$tmp/log"; check "the mint goes to the installation it found" $?
body=$(sed -n '/access_tokens/,$p' "$tmp/log" | grep '^{' | tail -1)
[ "$(jq -c . <<<"$body")" = '{"permissions":{"contents":"write"},"repositories":["cloud"]}' ]; check "the mint names the repository and exactly the permissions asked" $?
# The JWT: RS256, verifiable with the public half, iss = the App id, under ten minutes.
jwt=$(grep -m1 '^Authorization: Bearer [^.]*\.[^.]*\.' "$tmp/log" | sed 's/^Authorization: Bearer //')
h=${jwt%%.*}; rest=${jwt#*.}; p=${rest%%.*}; s=${rest#*.}
pad() { local x=$1; while [ $(( ${#x} % 4 )) -ne 0 ]; do x="$x="; done; printf '%s' "$x" | tr '_-' '/+'; }
printf '%s' "$h.$p" > "$tmp/signed"
pad "$s" | base64 -d > "$tmp/sig" 2>/dev/null
openssl dgst -sha256 -verify "$tmp/app.pub" -signature "$tmp/sig" "$tmp/signed" >/dev/null 2>&1; check "the JWT verifies RS256 against the App's public key" $?
claims=$(pad "$p" | base64 -d 2>/dev/null)
[ "$(jq -r .iss <<<"$claims")" = 1164624 ]; check "iss is the App id read from KMS" $?
jq -e '(.exp - .iat) <= 600 and (.exp - .iat) >= 60 and .iat < (now | floor)' <<<"$claims" >/dev/null; check "iat is back-dated and the life is under ten minutes" $?
! grep -q 'BEGIN' "$tmp/out" "$tmp/err" "$tmp/log"; check "the private key reaches no output and no request" $?

# 2. No repository: the whole installation, resolved by organisation.
run hanzoai '{"contents":"read"}'
grep -q 'REQ GET https://api.github.com/orgs/hanzoai/installation' "$tmp/log"; check "no repository resolves the installation by organisation" $?
body=$(sed -n '/access_tokens/,$p' "$tmp/log" | grep '^{' | tail -1)
[ "$(jq -c . <<<"$body")" = '{"permissions":{"contents":"read"}}' ]; check "no repository means no repositories key" $?

# 3. Several repositories travel as one list.
run hanzoai '{"contents":"read"}' amqp thinking
body=$(sed -n '/access_tokens/,$p' "$tmp/log" | grep '^{' | tail -1)
[ "$(jq -c .repositories <<<"$body")" = '["amqp","thinking"]' ]; check "several repositories travel as one list" $?

# 4. A key sealed on one line, its newlines written as \n, still signs.
routes "$tmp/kms_key_oneline" 200 201 "$tmp/inst" "$tmp/minted"
run hanzoai '{"contents":"read"}'
[ "$rc" = 0 ] && [ "$(cat "$tmp/out")" = "ghs_FAKE_INSTALLATION_TOKEN" ]; check "a key whose newlines are the two characters \\n signs" $?

# 5. Refusals that make no network call at all.
routes "$tmp/kms_key" 200 201 "$tmp/inst" "$tmp/minted"
run hanzoai '{}'
[ "$rc" = 2 ] && [ ! -s "$tmp/log" ] && grep -q 'non-empty' "$tmp/err"; check "an empty permission object is refused before any request" $?
run hanzoai ''
[ "$rc" = 2 ] && [ ! -s "$tmp/log" ]; check "no permissions at all is refused before any request" $?
run hanzoai '{"contents":"owner"}'
[ "$rc" = 2 ] && [ ! -s "$tmp/log" ]; check "a permission level GitHub does not have is refused" $?
run 'han zoai' '{"contents":"read"}'
[ "$rc" = 2 ] && [ ! -s "$tmp/log" ]; check "an account name with a space is refused" $?
run hanzoai '{"contents":"read"}' 'a/b'
[ "$rc" = 2 ] && [ ! -s "$tmp/log" ]; check "a repository name with a slash is refused" $?

# 6. GitHub's refusals name themselves and print no token.
routes "$tmp/kms_key" 404 201 "$tmp/notfound" "$tmp/minted"
run luxfi '{"contents":"read"}'
[ "$rc" = 1 ] && [ ! -s "$tmp/out" ] && grep -q 'is not installed on luxfi' "$tmp/err"; check "an owner the App is not installed on is named" $?
routes "$tmp/kms_key" 200 403 "$tmp/inst" "$tmp/denied"
run hanzoai '{"contents":"read"}'
[ "$rc" = 1 ] && [ ! -s "$tmp/out" ] && grep -q 'Resource not accessible' "$tmp/err"; check "a refused mint says why and prints no token" $?

# 7. KMS without the key is a failure, not an empty token.
cat > "$tmp/routes" <<EOF
GET /v1/kms/secrets/platform/GITHUB_APP_ID 200 $tmp/kms_id
GET /v1/kms/secrets/platform/GITHUB_APP_PRIVATE_KEY 404 $tmp/notfound
EOF
run hanzoai '{"contents":"read"}'
[ "$rc" = 1 ] && [ ! -s "$tmp/out" ] && ! grep -q 'api.github.com' "$tmp/log"; check "an unsealed key stops before GitHub is asked" $?

# 8. A value that is not a key does not sign.
reply kms_junk '{"value":"not a key"}'
cat > "$tmp/routes" <<EOF
GET /v1/kms/secrets/platform/GITHUB_APP_ID 200 $tmp/kms_id
GET /v1/kms/secrets/platform/GITHUB_APP_PRIVATE_KEY 200 $tmp/kms_junk
EOF
run hanzoai '{"contents":"read"}'
[ "$rc" = 1 ] && grep -q 'not an RSA private key' "$tmp/err" && ! grep -q 'api.github.com' "$tmp/log"; check "a value that is not an RSA key is named and goes no further" $?

echo
[ $fail -eq 0 ] && echo "apptoken: all cases pass" || echo "apptoken: FAILURES"
exit $fail
