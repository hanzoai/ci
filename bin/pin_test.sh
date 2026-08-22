#!/usr/bin/env bash
# Tests for bin/pin. Offline and deterministic: every case is a real git repo
# built in a temp dir with a real commit on a real remote, so this needs no
# network and no module proxy — `go list` is stubbed on PATH, which is also the
# only way to pin "latest" to a known value.
# Run: bash bin/pin_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PIN="$PWD/bin/pin"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# A stub `go` that answers latest=v2.0.0 and nothing else. Placed first on PATH.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/go" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "list" ] && { echo "v2.0.0"; exit 0; }
exit 0
STUB
chmod +x "$tmp/stub/go"

# repo <name> <pinned-version> makes a repo whose ORIGIN/MAIN pins that version,
# and whose working copy pins something else — the case the tool exists to get
# right.
repo() {
  local name=$1 ver=${2:-} d="$tmp/$1" bare="$tmp/$1.git"
  git init -q --bare "$bare"
  git init -q "$d"; cd "$d"
  git config user.email t@t; git config user.name t
  if [ -n "$ver" ]; then
    printf 'module x\n\ngo 1.26\n\nrequire example.com/lib %s\n' "$ver" >go.mod
  else
    printf 'module x\n\ngo 1.26\n' >go.mod
  fi
  git add -A; git commit -qm one
  git branch -M main; git remote add origin "$bare"; git push -q origin main
  # the checkout now disagrees with its own branch, uncommitted
  printf 'module x\n\ngo 1.26\n\nrequire example.com/lib v9.9.9\n' >go.mod
  cd - >/dev/null
}

t() { # t <name> <expect-substring> <args...>
  local name=$1 want=$2; shift 2
  local out; out=$(PATH="$tmp/stub:$PATH" bash "$PIN" "$@" 2>&1)
  if grep -qF -- "$want" <<<"$out"; then
    echo "ok   $name"
  else
    echo "FAIL $name: want substring $want, got:"; sed 's/^/       /' <<<"$out"; fail=1
  fi
}

repo behind v1.0.0
repo current v2.0.0
repo nodep

# THE POINT OF THE TOOL: the branch is read, not the checkout. The working copy
# says v9.9.9; main says v1.0.0; the report must say v1.0.0.
t "reads the branch not the checkout" "behind           v1.0.0     -> v2.0.0" example.com/lib "$tmp/behind"
t "the row names the remote it read" "(origin)" example.com/lib "$tmp/behind"
t "a current repo is silent" "0 of 1 behind" example.com/lib "$tmp/current"
t "counts what is behind, out of what depends" "1 of 2 behind" example.com/lib "$tmp/behind" "$tmp/current"
t "a repo with no such dependency is not counted" "0 of 0 behind" example.com/lib "$tmp/nodep"
t "a path that is not a repo is silent" "0 of 0 behind" example.com/lib "$tmp/absent"

# Usage is a refusal, not a guess.
out=$(PATH="$tmp/stub:$PATH" bash "$PIN" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "ok   no arguments is a usage error" ||
  { echo "FAIL no arguments: rc=$rc"; fail=1; }

# An unresolvable module is fatal, and says which — never a sweep that reports
# every repo as behind an empty string.
cat >"$tmp/stub/go" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$tmp/stub/go"
out=$(PATH="$tmp/stub:$PATH" bash "$PIN" example.com/lib "$tmp/behind" 2>&1); rc=$?
{ [ $rc -eq 1 ] && grep -q "cannot resolve" <<<"$out"; } &&
  echo "ok   an unresolvable module is fatal" ||
  { echo "FAIL unresolvable: rc=$rc $out"; fail=1; }

# --apply is the half that writes, and it was the half with no test — a sweep
# reported a syntax error from a block nothing had ever run. The stub `go`
# answers every command, so the build and test steps pass and what is exercised
# here is the part that broke: commit, push, and the report of both.
# The unresolvable case above left the stub failing on purpose; put it back — and
# this one WRITES the bump, because a `go get` that changes nothing leaves nothing
# to commit and would test only git's refusal of an empty commit.
cat >"$tmp/stub/go" <<STUB
#!/usr/bin/env bash
[ "\${1:-}" = "list" ] && { echo "v2.0.0"; exit 0; }
[ "\${1:-}" = "get" ] && { sed -i 's/v1.0.0/v2.0.0/' go.mod 2>/dev/null; exit 0; }
exit 0
STUB
chmod +x "$tmp/stub/go"

repo applyme v1.0.0
out=$(PATH="$tmp/stub:$PATH" bash "$PIN" --apply example.com/lib "$tmp/applyme" 2>&1)
if grep -q "applyme          v1.0.0     -> v2.0.0 pushed" <<<"$out"; then
  echo "ok   --apply commits and pushes"
else
  echo "FAIL --apply: $out"; fail=1
fi
# The push must have actually LANDED on the branch, not merely been reported.
if git -C "$tmp/applyme.git" show main:go.mod 2>/dev/null | grep -q 'v2.0.0'; then
  echo "ok   --apply lands the bump on the branch"
else
  echo "FAIL --apply did not land: $(git -C "$tmp/applyme.git" show main:go.mod 2>&1 | tr '\n' ' ')"; fail=1
fi
# And the repo is now current, so a second run finds nothing to do.
out=$(PATH="$tmp/stub:$PATH" bash "$PIN" example.com/lib "$tmp/applyme" 2>&1)
grep -q "0 of 1 behind" <<<"$out" &&
  echo "ok   a bumped repo is no longer behind" ||
  { echo "FAIL second run: $out"; fail=1; }

# A remote's NAME does not say whether it is the forge. Build a repo whose forge
# is named `origin` and whose mirror is named `github`, with the mirror AHEAD:
# picking by name reads the mirror and reports the wrong version, which is how a
# real fix went to a mirror while the forge — what a build reads — stayed behind.
mirror() {
  local d="$tmp/twohome" fake="$tmp/twohome-forge.git" gh="$tmp/twohome-github.git"
  git init -q --bare "$fake"; git init -q --bare "$gh"
  git init -q "$d"; cd "$d"
  git config user.email t@t; git config user.name t
  printf 'module x\n\ngo 1.26\n\nrequire example.com/lib v1.0.0\n' >go.mod
  git add -A; git commit -qm one; git branch -M main
  git remote add origin "$fake"; git push -q origin main
  # the mirror is AHEAD and already current, so reading it hides the real gap
  printf 'module x\n\ngo 1.26\n\nrequire example.com/lib v2.0.0\n' >go.mod
  git commit -qam two; git remote add github "$gh"; git push -q github main
  git reset -q --hard origin/main
  # git.hanzo.ai is the forge in production; name the fake one so pin sees it
  git remote set-url origin "https://git.hanzo.ai/fake/twohome.git"
  cd - >/dev/null
}
mirror
# pin cannot fetch the rewritten URL, so it reads the ref it already has — which
# is the point: the ref it keeps for the FORGE remote, not the mirror's.
out=$(PATH="$tmp/stub:$PATH" bash "$PIN" example.com/lib "$tmp/twohome" 2>&1)
grep -q "twohome          v1.0.0     -> v2.0.0     (origin)" <<<"$out" &&
  echo "ok   the forge is chosen by URL, not by remote name" ||
  { echo "FAIL two-remote pick: $out"; fail=1; }

exit $fail
