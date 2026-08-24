#!/usr/bin/env bash
# bin/kms — what it must do without a live KMS.
#
# The three copies this script replaced all failed the same way in a log: an
# outage, a refusal and an unsealed secret were indistinguishable. So the thing
# under test is which SENTENCE comes out, and how many times it asks.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
check() { # check <name> <expected-substring> <actual>
  case "$3" in *"$2"*) ;; *) echo "FAIL $1: wanted /$2/, got: $3"; fails=$((fails+1)) ;; esac
}

out=$(KMS_CLIENT_ID= KMS_CLIENT_SECRET= bash bin/kms NAME 2>&1); rc=$?
check "no credential names both variables" "KMS_CLIENT_ID and KMS_CLIENT_SECRET are unset" "$out"
[ "$rc" -eq 1 ] || { echo "FAIL no credential: rc=$rc want 1"; fails=$((fails+1)); }

out=$(bash bin/kms 2>&1); rc=$?
check "no name is a usage error" "usage: kms <NAME>" "$out"
[ "$rc" -eq 2 ] || { echo "FAIL usage: rc=$rc want 2"; fails=$((fails+1)); }

# A REFUSAL is taken on the first try. An endpoint that answers 401 immediately
# must not be retried — four waits would add a minute to a build that is already
# going to fail, and the old copies could not tell this from an outage.
start=$SECONDS
out=$(KMS_CLIENT_ID=x KMS_CLIENT_SECRET=y KMS_ENDPOINT=https://kms.hanzo.ai bash bin/kms NAME 2>&1); rc=$?
took=$((SECONDS - start))
check "a refusal names the code" "refused the login: HTTP 401" "$out"
[ "$rc" -eq 1 ] || { echo "FAIL refusal: rc=$rc want 1"; fails=$((fails+1)); }
[ "$took" -lt 20 ] || { echo "FAIL refusal took ${took}s — 401 is KMS answering and must not be retried"; fails=$((fails+1)); }

# AN OUTAGE asks again and says so. A refused port yields 000 four times —
# refused rather than black-holed, so the case costs the retry schedule and not
# four connect timeouts on top of it. The message must not read as a missing
# secret, which is the sentence that sent a day of publishes looking for a token
# that was sealed the whole time.
out=$(KMS_CLIENT_ID=x KMS_CLIENT_SECRET=y KMS_ENDPOINT=http://127.0.0.1:1 bash bin/kms NAME 2>&1); rc=$?
check "an outage says it is one" "An outage, not a missing secret" "$out"
check "an outage names the tries" "over four tries" "$out"
[ "$rc" -eq 1 ] || { echo "FAIL outage: rc=$rc want 1"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "bin/kms: ok" || { echo "bin/kms: $fails failed"; exit 1; }
