#!/usr/bin/env bash
# Mint the reviewer's identity, then read the change.
#
# A reviewer that cannot be reached withholds no verdict and exits 0. A
# reviewer that refuses the change exits 1. The secret is piped into the token
# request and never assigned, exported, or placed on a command line.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
BASE="${1:-}"
HEAD="${2:-${GITHUB_SHA:-HEAD}}"
case "$BASE" in
  ""|0000000*)
    BASE=$(git describe --tags --abbrev=0 --match 'v*' "$HEAD" 2>/dev/null \
      || git rev-parse "$HEAD~1" 2>/dev/null \
      || git rev-parse "$HEAD")
    ;;
esac

API_KMS="${KMS_ENDPOINT:-https://api.hanzo.ai}"
KMS_ENV="${KMS_SECRET_ENV:-prod}"
IAM="${IAM_ENDPOINT:-https://iam.hanzo.ai}"
CLIENT_NAME="${REVIEW_CLIENT:-hanzo-review}"

if [ -z "${REVIEW_TOKEN:-}" ]; then
  if [ -z "${KMS_CLIENT_ID:-}" ] || [ -z "${KMS_CLIENT_SECRET:-}" ]; then
    echo "::warning::review: no KMS identity on this repo — the reviewer did not run, so it withholds no verdict"
    exit 0
  fi

  KMS_BODY=$(mktemp); KMS_CODE=$(mktemp)
  trap 'rm -f "$KMS_BODY" "$KMS_CODE"' EXIT
  login() {
    jq -Rsj --arg id "$1" '{clientId: $id, clientSecret: rtrimstr("\n")}' \
      | curl -sS --max-time 30 -o "$KMS_BODY" -w '%{http_code}' \
          "${API_KMS}/v1/kms/auth/login" \
          -H 'content-type: application/json' --data-binary @- \
          > "$KMS_CODE" || true
    jq -r '.accessToken // empty' < "$KMS_BODY" 2>/dev/null || true
  }
  again() {
    local attempt=1 out=
    while :; do
      out=$("$@" || true)
      [ -n "$out" ] && { printf %s "$out"; return 0; }
      [ "$attempt" -ge 6 ] && return 1
      sleep $(( attempt * 5 ))
      attempt=$(( attempt + 1 ))
    done
  }
  refused() { case "${1:-000}" in 4??) return 0;; *) return 1;; esac; }

  kms_login() { printf %s "$KMS_CLIENT_SECRET" | login "$KMS_CLIENT_ID"; }
  KMS_TOKEN=$(again kms_login || true)
  if [ -z "$KMS_TOKEN" ]; then
    code=$(cat "$KMS_CODE" 2>/dev/null || echo 000)
    said=$(head -c 200 "$KMS_BODY" 2>/dev/null)
    if refused "$code"; then
      echo "::error::review: KMS login at ${API_KMS} answered ${code} — ${said}. The store refused this credential, so the reviewer has no identity."
      exit 1
    fi
    echo "::warning::review: KMS login at ${API_KMS} answered ${code} — the reviewer did not run, so it withholds no verdict"
    exit 0
  fi

  KMS_CODE_F=$(mktemp)
  kms_secret() {
    body=$(mktemp)
    curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
        "${API_KMS}/v1/kms/secrets/review/$1?env=${KMS_ENV}" \
        -H "Authorization: Bearer ${KMS_TOKEN}" > "$KMS_CODE_F" 2>/dev/null \
      || echo 000 > "$KMS_CODE_F"
    [ "$(cat "$KMS_CODE_F")" = 200 ] \
      && jq -r '.value // .secret.value // empty' < "$body" 2>/dev/null
    rm -f "$body"
  }
  REVIEW_CLIENT_ID=$(again kms_secret IAM_CLIENT_ID || true)
  if [ -z "$REVIEW_CLIENT_ID" ]; then
    code=$(cat "$KMS_CODE_F" 2>/dev/null || echo 000)
    if [ "$code" = 200 ] || refused "$code"; then
      echo "::error::review: the store answered ${code} for review/IAM_CLIENT_ID, so ${CLIENT_NAME} has no identity."
      exit 1
    fi
    echo "::warning::review: the store did not answer for review/IAM_CLIENT_ID — the reviewer did not run, so it withholds no verdict"
    exit 0
  fi

  mint_review() {
    kms_secret IAM_CLIENT_SECRET \
      | jq -Rsj --arg id "$REVIEW_CLIENT_ID" '"user = \"\($id):\(rtrimstr("\n"))\"\n"' \
      | curl -sS --max-time 30 --config - "${IAM}/v1/iam/oauth/token" \
          -d 'grant_type=client_credentials' \
      | jq -r '.access_token // empty'
  }
  REVIEW_TOKEN=$(again mint_review || true)
  if [ -z "$REVIEW_TOKEN" ]; then
    echo "::warning::review: IAM issued no token to ${CLIENT_NAME} at ${IAM} — the reviewer did not run, so it withholds no verdict"
    exit 0
  fi
  export REVIEW_TOKEN
  echo "::add-mask::${REVIEW_TOKEN}"
fi

exec bash "$here/review.sh" "$BASE" "$HEAD"
