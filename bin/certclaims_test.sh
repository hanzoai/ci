#!/usr/bin/env bash
# certclaims_test.sh — the cases certclaims exists for, and the ones it must not
# fire on. Every FAIL case below is a sentence that was live on a Hanzo surface.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; git init -q .

want() { # want <expect-exit> <name> <line>
  local expect="$1" name="$2" line="$3"
  rm -f ./*.tsx; printf '%s\n' "$line" > "case.tsx"; git add -A >/dev/null 2>&1
  set +e; "$here/certclaims" . >/dev/null 2>&1; local got=$?; set -e
  if [ "$got" != "$expect" ]; then echo "FAIL($name): want exit $expect, got $got"; echo "  $line"; exit 1; fi
  echo "  ok: $name"
}

echo "must FAIL (claims we cannot produce):"
want 1 "certified"        'SOC 2 Type II certified, GDPR compliant, and ISO 27001 certified'
want 1 "third-party"      'audited and certified by independent third-party auditors'
want 1 "report under NDA" 'Our SOC 2 report is available to enterprise customers under NDA.'
want 1 "maintains"        'We maintain SOC 2 Type II certification'
want 1 "completed"        'has completed SOC 2 Type II certification'

echo "must PASS (honest, and must stay sayable):"
want 0 "denial"      'We do not hold SOC 2 Type II, ISO 27001 or HIPAA certification today.'
want 0 "controls"    'Controls aligned to the SOC 2 Type II control set.'
want 0 "in progress" 'SOC 2 Type II audit in progress.'
want 0 "planned"     'SOC 2 Type II — controls aligned; assessment planned'
want 0 "no framework" 'Encryption at rest with per-tenant keys.'

echo "certclaims: all cases pass"
