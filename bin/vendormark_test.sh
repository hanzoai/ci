#!/usr/bin/env bash
# vendormark_test.sh — the refusals AND the allowances, both pinned.
#
# A gate is only worth having if it is exact in both directions. A false
# negative lets the vendor's mark back into a shipped site; a false positive
# reds a repo that was always fine, and a gate that reds honest repos is a gate
# someone switches off. So this suite asserts BOTH halves, and the allowance
# half is the larger one on purpose: the vendor's name is also an ordinary
# English adjective, and it occurs innocently in tokenizer vocabularies, word
# lists, ML corpora, packed public-suffix data and third-party host lists all
# over the estate.
#
# Offline and deterministic: temp repos, no network.
set -uo pipefail
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vendormark
pass=0; fail=0
V=$(printf 'lo%s' 'vable')   # not spelled literally, so this file does not
                             # itself trip the gate it is testing

newrepo() {
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email dev@hanzo.ai
  git -C "$d" config user.name "Hanzo Dev"
  printf 'x\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -qm "initial"
  echo "$d"
}
check() { # name expected_rc dir [range]
  local name=$1 want=$2 dir=$3 range=${4:-}
  "$BIN" "$dir" $range >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want rc=$want, got rc=$got)"; fi
}

echo "REFUSALS — the mark in each of the four places it hides"

d=$(newrepo)
check "clean repo is green" 0 "$d"
mkdir -p "$d/public/$V-uploads"
printf 'PNG\n' > "$d/public/$V-uploads/28d53ec4.png"
git -C "$d" add -A && git -C "$d" commit -qm "add an image"
check "MUTATION: tracked path named for the vendor" 1 "$d"
git -C "$d" rm -rq "public/$V-uploads" && git -C "$d" commit -qm "move the image"
check "MUTATION REVERTED: green again" 0 "$d"
rm -rf "$d"

d=$(newrepo)
printf '<img src="/%s-uploads/28d53ec4.png" />\n' "$V" > "$d/index.html"
git -C "$d" add -A && git -C "$d" commit -qm "a page"
check "content: asset folder referenced in markup" 1 "$d"
rm -rf "$d"

d=$(newrepo)
printf '{"devDependencies":{"%s-tagger":"^1.1.3"}}\n' "$V" > "$d/package.json"
git -C "$d" add -A && git -C "$d" commit -qm "deps"
check "content: the vendor's build plugin in package.json" 1 "$d"
rm -rf "$d"

d=$(newrepo)
printf '<script src="https://cdn.gpteng.co/gptengineer.js"></script>\n' > "$d/index.html"
git -C "$d" add -A && git -C "$d" commit -qm "a page"
check "content: the vendor's injected script tag" 1 "$d"
rm -rf "$d"

d=$(newrepo)
printf '<meta name="generator" content="Lovable" />\n' > "$d/index.html"
git -C "$d" add -A && git -C "$d" commit -qm "a page"
check "content: the generator meta tag" 1 "$d"
rm -rf "$d"

d=$(newrepo)
printf 'y\n' > "$d/a.txt"; git -C "$d" add -A
git -C "$d" commit -qm "Update $V project template"
check "MUTATION: the vendor named in a commit message" 1 "$d"
git -C "$d" commit -q --amend -m "update the project template"
check "MUTATION REVERTED: reworded message is green" 0 "$d"
rm -rf "$d"

d=$(newrepo)
printf 'y\n' > "$d/a.txt"; git -C "$d" add -A
# --no-verify ON PURPOSE. A commit-msg hook on the workstation
# (~/.githooks/commit-msg) already strips vendor co-author trailers, and with it
# enabled this case cannot be constructed — the hook silently rewrites the
# trailer to ours and the assertion passes for the wrong reason. That hook is
# per-machine: it does not run on a runner, on a teammate's laptop, or on a
# commit made through the GitHub web UI. This gate is the layer that does. So
# the test bypasses the hook to prove the GATE catches what the hook would have.
git -C "$d" commit -q --no-verify -m "a change

Co-authored-by: $V bot <bot@$V.dev>"
check "MUTATION: Co-authored-by credits the vendor" 1 "$d"
git -C "$d" commit -q --amend --no-verify -m "a change"
check "MUTATION REVERTED: trailer dropped is green" 0 "$d"
rm -rf "$d"

d=$(newrepo)
printf 'y\n' > "$d/a.txt"; git -C "$d" add -A
git -C "$d" -c user.name="$V" -c user.email="bot@$V.dev" commit -qm "a change"
check "MUTATION: the vendor as author identity" 1 "$d"
rm -rf "$d"

d=$(newrepo)
printf 'y\n' > "$d/a.txt"; git -C "$d" add -A; git -C "$d" commit -qm "clean subject"
printf 'z\n' > "$d/b.txt"; git -C "$d" add -A; git -C "$d" commit -qm "Visual edit in $V"
printf 'w\n' > "$d/c.txt"; git -C "$d" add -A; git -C "$d" commit -qm "clean again"
check "default scope (HEAD only) misses an older bad message" 0 "$d"
check "explicit range catches it" 1 "$d" "HEAD~3..HEAD"
rm -rf "$d"

echo
echo "ALLOWANCES — the same word, innocently, as it really occurs in the estate"

d=$(newrepo)
printf '  "%s</w>": 38565,\n' "$V" > "$d/vocab.json"
printf '%s\n' "$V" > "$d/words_alpha.txt"
printf 'Tell me a story about a %s character.\n' "$V" > "$d/harmless.txt"
printf 'caseStudy: %s and v0 activate users by turning a prompt into an app\n' "${V^}" > "$d/guide.yaml"
printf 'mail2%s.com\n' "$V" > "$d/generic_emails.txt"
printf 'let e=[".%s.app",".%sproject.com",".webcontainer-api.io"];\n' "$V" "$V" > "$d/clerk-bundle.js"
printf 'A collection of UI components. Integrate them in v0, %s, Bolt.\n' "${V^}" > "$d/registries.json"
git -C "$d" add -A && git -C "$d" commit -qm "corpora, word lists and third-party bundles"
check "tokenizer vocab / word list / ML corpus / marketing prose / blocklist / upstream host list" 0 "$d"
rm -rf "$d"

echo
echo "ESCAPE HATCH — a repo whose job is to name the vendor"

d=$(newrepo)
mkdir -p "$d/tools/rules"
printf 'Hanzo Dev <dev@hanzo.ai> <bot@%s.dev>\n' "$V" > "$d/tools/rules/mailmap.txt"
git -C "$d" add -A && git -C "$d" commit -qm "scrubber rules"
check "scrubber rule file is refused by default" 1 "$d"
printf 'tools/rules/*\n' > "$d/.vendormark-allow"
git -C "$d" add -A && git -C "$d" commit -qm "declare the rule files"
check "...and allowed once declared in .vendormark-allow" 0 "$d"
rm -rf "$d"

echo
echo "vendormark_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
