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

exit $fail
