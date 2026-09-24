#!/usr/bin/env bash
# Tests for the `enqueue` function the delegate lane POSTs every build to the
# door with. There is no bin/enqueue: the function lives in
# .github/workflows/build.yml, and this suite LIFTS IT OUT and runs it, the way
# bin/kind_test.sh does, so what is tested is the text the runner executes.
#
# The wire and the clock are faked. curl is a function that answers from a
# script of codes, one per call; sleep is a function that records how long it
# was asked for and advances SECONDS by that much, so a 30-minute budget runs in
# milliseconds. SECONDS is unset first, which strips bash's ticking and leaves a
# plain variable only the fake sleep moves: on a starved runner the real clock
# ran 14s during this suite and the budget came out 1786.
#
# Weighted toward the two ways a wait goes wrong: a refusal asked again, and a
# budget overrun. Offline. Run: bash bin/enqueue_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEF=.github/workflows/build.yml
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0 ran=0

sed -n '/^          # enqueue BEGIN$/,/^          # enqueue END$/p' "$DEF" | sed 's/^          //' > "$tmp/enqueue.sh"
grep -q '^enqueue() {' "$tmp/enqueue.sh" || {
  echo "FAIL  could not lift enqueue() out of $DEF — the BEGIN/END markers moved, fix this suite"; exit 1; }
# shellcheck disable=SC1090
. "$tmp/enqueue.sh"

HANZO_API_TOKEN=tok-test
# Each line of $tmp/script is one answer: `<code> [Retry-After value]`. The
# last line repeats once the script runs out, so "429 forever" is one line.
curl() {
  local out=/dev/null hdr=/dev/null body= auth= n line code ra
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out=$2; shift 2 ;;
      -D) hdr=$2; shift 2 ;;
      -d) body=$2; shift 2 ;;
      -H) case "$2" in Authorization:*) auth=$2 ;; esac; shift 2 ;;
      *) shift ;;
    esac
  done
  n=$(( $(cat "$tmp/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$tmp/n"
  printf '%s|%s\n' "$auth" "$body" >> "$tmp/calls"
  line=$(sed -n "${n}p" "$tmp/script"); [ -n "$line" ] || line=$(tail -1 "$tmp/script")
  read -r code ra <<< "$line"
  # 000 is curl's own "nothing arrived": no headers, no body, a non-zero exit.
  if [ "$code" = 000 ]; then printf '000'; return 7; fi
  printf 'HTTP/2 %s\r\n' "$code" > "$hdr"
  [ -z "$ra" ] || printf 'Retry-After: %s\r\n' "$ra" >> "$hdr"
  printf '{"answer":%s}' "$code" > "$out"
  printf '%s' "$code"
}
unset SECONDS; SECONDS=0
sleep() { echo "$1" >> "$tmp/sleeps"; SECONDS=$(( SECONDS + $1 )); }

# ask <answer lines...> — run enqueue against that script; sets got, log, calls,
# sleeps (space-separated), slept (their sum).
ask() {
  rm -f "$tmp/n" "$tmp/calls" "$tmp/out" "$tmp/out.hdr"; : > "$tmp/sleeps"
  printf '%s\n' "$@" > "$tmp/script"
  got=$(enqueue https://door.test/v1/build '{"image":"x"}' "$tmp/out" 2> "$tmp/log")
  log=$(cat "$tmp/log")
  calls=$(wc -l < "$tmp/calls" | tr -d ' ')
  sleeps=$(tr "\n" " " < "$tmp/sleeps" | sed "s/ \$//")
  slept=0; for s in $sleeps; do slept=$(( slept + s )); done
}
# One `ok` or `FAIL` line per assertion: the reusable's test tally counts
# those, and a suite that prints only a summary reads as one that ran nothing.
is() { ran=$((ran+1)); if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: want [$3], got [$2]"; fail=1; fi; }
has() { ran=$((ran+1)); case "$2" in *"$3"*) echo "ok    $1" ;; *) echo "FAIL  $1: want /$3/ in: $2"; fail=1 ;; esac; }
within() { # within <name> <value> <lo> <hi>
  ran=$((ran+1)); if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then echo "ok    $1"; else echo "FAIL  $1: want $3..$4, got $2"; fail=1; fi; }

# Accepted at once: one ask, no wait, the door's reply left where the step reads it.
ask 202
is  "202 is the answer"            "$got"   202
is  "202 asks once"                "$calls" 1
is  "202 waits for nothing"        "$sleeps" ""
is  "the reply is left in <out>"   "$(cat "$tmp/out")" '{"answer":202}'
is  "the org's identity is sent"   "$(cut -d'|' -f1 "$tmp/calls")" "Authorization: Bearer tok-test"

# A REFUSAL IS TAKEN AT ONCE. A 400 or 403 does not become valid by being asked
# again, and a wait before it only delays the red.
for c in 400 401 403 404 409 500; do
  ask "$c"
  is "$c is taken at once" "$got/$calls/$sleeps" "$c/1/"
done

# The ceiling waits, and the schedule backs off: each wait sits in the upper
# half of a step that doubles from 15s, and every try says what it is waiting on.
ask 429 429 429 202
is  "429 then a slot is the slot"  "$got"   202
is  "three 429s ask four times"    "$calls" 4
set -- $sleeps
within "first wait backs off from 15s"  "${1:-0}" 7  15
within "second wait doubles"            "${2:-0}" 15 30
within "third wait doubles again"       "${3:-0}" 30 60
has "a wait names the ceiling"     "$log" "per-org build ceiling (HTTP 429); try 1, next in"
has "a wait names its budget"      "$log" "s of budget left"
is  "every try sends the same body" "$(cut -d'|' -f2 "$tmp/calls" | sort -u)" '{"image":"x"}'

# Cloud restarting is waited out too — a 5xx from the edge, or nothing at all.
ask 503 000 502 504 202
is  "an outage then a slot"        "$got/$calls" 202/5
has "no answer is named"           "$log" "not answering (HTTP 000)"
has "a 503 is named"               "$log" "not answering (HTTP 503)"

# RETRY-AFTER IS A FLOOR on the next wait, never a ceiling on it.
ask "429 90" 202
is  "Retry-After 90 waits 90"      "$sleeps" 90
has "Retry-After is named"         "$log" "(Retry-After: 90s)"
ask "429 3" 202
within "a short Retry-After does not shorten the backoff" "${sleeps:-0}" 7 15
# The date form is not read; the schedule stands in for it.
ask "429 Wed, 21 Oct 2026 07:28:00 GMT" 202
within "an HTTP-date Retry-After falls back to the schedule" "${sleeps:-0}" 7 15
# A header file is per try: a Retry-After from one answer must not stretch the
# wait after a later answer that carried none.
ask "429 90" 000 202
set -- $sleeps
is     "first wait is the Retry-After"         "${1:-0}" 90
within "a stale Retry-After is not re-read"    "${2:-0}" 15 30

# THE BUDGET IS THIRTY MINUTES AND IS NEVER OVERRUN. A door full for longer is
# asked until the clock is spent — the last wait trimmed to what is left — once
# more at the edge, and then its answer is the step's.
ask 429
is  "a full door is refused as 429"      "$got"   429
is  "the waits spend the budget"          "$slept" 1800
has "giving up says how long it asked"   "$log"   "over 30 minutes — giving up"
max=0; for s in $sleeps; do [ "$s" -le "$max" ] || max=$s; done
within "no wait passes the 120s ceiling"  "$max" 1 120
within "the tries are bounded"            "$calls" 16 60
# A Retry-After longer than the budget is trimmed to it, not obeyed past it.
ask "429 99999"
is  "a huge Retry-After is trimmed to the budget" "${sleeps:-0}" 1800
is  "and asked once more at the edge"             "$calls" 2

if [ "$fail" = 0 ]; then echo "OK: enqueue — $ran assertions"; else exit 1; fi
