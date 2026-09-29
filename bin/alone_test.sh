#!/usr/bin/env bash
# Tests for `alone`, which installs a built wheel into a venv holding nothing
# else and imports what the wheel says it provides, before the PyPI lane
# uploads it. There is no bin/alone: the function lives in
# .github/workflows/build.yml, and this suite lifts it out and runs that text.
#
# The case it exists for: `uv venv` makes a venv without pip, so a bare one
# answered `No module named pip` for every wheel and the lane published nothing.
#
# Needs uv, which the gate provisions as the pipeline does, and the index for
# the pip the venv is seeded with. Run: bash bin/alone_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

command -v uv >/dev/null 2>&1 || {
  echo "FAIL  uv is not on PATH — the lane runs under uv, and a suite that cannot run must not read as passed"; exit 1; }

sed -n '/^          # alone BEGIN$/,/^          # alone END$/p' "$DEF" | sed 's/^          //' > "$tmp/alone.sh"
grep -q '^alone() {' "$tmp/alone.sh" || {
  echo "FAIL  could not lift alone() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }

# wheel <name> <module source>: a pure wheel with no dependencies, in $tmp/<name>/.
wheel() {
  mkdir -p "$tmp/$1"
  uv run -q --no-project --python 3.12 python - "$tmp/$1" "$1" "$2" <<'PY'
import base64, hashlib, sys, zipfile
out, name, src = sys.argv[1:4]
di = f"{name}-0.1.0.dist-info"
files = {
    f"{name}/__init__.py": src,
    f"{di}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: 0.1.0\n",
    f"{di}/WHEEL": "Wheel-Version: 1.0\nGenerator: alone_test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{di}/top_level.txt": f"{name}\n",
}
def rec(data):
    d = base64.urlsafe_b64encode(hashlib.sha256(data.encode()).digest()).rstrip(b"=").decode()
    return f"sha256={d},{len(data.encode())}"
record = "".join(f"{p},{rec(s)}\n" for p, s in files.items()) + f"{di}/RECORD,,\n"
with zipfile.ZipFile(f"{out}/{name}-0.1.0-py3-none-any.whl", "w") as z:
    for p, s in files.items():
        z.writestr(p, s)
    z.writestr(f"{di}/RECORD", record)
PY
}

wheel declared 'import json'
wheel undeclared 'import hanzo_alone_absent'
mkdir -p "$tmp/broken"; echo 'not a zip' > "$tmp/broken/broken-0.1.0-py3-none-any.whl"

# check <name> <distribution> <want rc> <want output>
check() {
  local name=$1 dist=$2 want=$3 match=$4 out rc
  out=$(bash -c '. "$1"; alone "$2" "$3"/*.whl' _ "$tmp/alone.sh" "$dist" "$tmp/$dist" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && grep -q -- "$match" <<<"$out"; then echo "ok   $name"; else
    echo "FAIL $name: want rc=$want and [$match], got rc=$rc: $out"; fail=1; fi
}

check "a wheel that declares what it imports installs and imports" declared   0 "declared: imported declared"
check "a wheel that imports what it does not declare is refused"   undeclared 1 "installs but does not import"
check "a file that is not a wheel does not install"                broken     1 "does not install"

exit $fail
