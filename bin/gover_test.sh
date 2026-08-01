#!/usr/bin/env bash
# Tests for bin/gover. Offline and deterministic: every case is a Dockerfile and
# a go.mod written into a temp dir, so this needs no registry and no network.
# Run: bash bin/gover_test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
GOVER="$PWD/bin/gover"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# t <name> <want-rc> <go.mod-directive> <dockerfile-body...>
t() {
  local name=$1 want=$2 gomod=$3; shift 3
  local d="$tmp/$RANDOM$RANDOM"; mkdir -p "$d"
  printf 'module x\n\ngo %s\n' "$gomod" > "$d/go.mod"
  printf '%s\n' "$@" > "$d/Dockerfile"
  out=$(cd "$d" && bash "$GOVER" Dockerfile . 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then printf 'ok    %-56s rc=%s\n' "$name" "$rc"
  else printf 'FAIL  %-56s rc=%s (want %s)\n      %s\n' "$name" "$rc" "$want" "$out"; fail=1; fi
}
# grep-based assertion for the message body, not just the code
tmsg() {
  local name=$1 pat=$2 gomod=$3; shift 3
  local d="$tmp/$RANDOM$RANDOM"; mkdir -p "$d"
  printf 'module x\n\ngo %s\n' "$gomod" > "$d/go.mod"
  printf '%s\n' "$@" > "$d/Dockerfile"
  out=$(cd "$d" && bash "$GOVER" Dockerfile . 2>&1)
  if printf '%s' "$out" | grep -q "$pat"; then printf 'ok    %-56s\n' "$name"
  else printf 'FAIL  %-56s\n      got: %s\n' "$name" "$out"; fail=1; fi
}

# --- the refusal: image below the module floor ------------------------------
# This is the visor v1.108.16 shape exactly.
t "patch below floor is refused"          1 1.26.5 'FROM golang:1.26.4-alpine'
t "minor below floor is refused"          1 1.26.5 'FROM golang:1.25-alpine'
t "ancient relic is refused"              1 1.26.4 'FROM golang:1.10.1'
t "second stage is checked too"           1 1.26.5 'FROM node:22 AS web' 'FROM golang:1.26.1-bookworm AS api'

# --- the allowances ---------------------------------------------------------
t "exact match builds"                    0 1.26.5 'FROM golang:1.26.5-alpine'
t "newer image than floor is fine"        0 1.26.4 'FROM golang:1.26.5-alpine'
t "much newer image is fine"              0 1.25.0 'FROM golang:1.26.5-bookworm'
t "alpine suffix is not a Go patch"       0 1.26   'FROM golang:1.26-alpine3.24'
t "registry prefix is stripped"           0 1.26.5 'FROM docker.io/library/golang:1.26.5-alpine'
t "--platform flag is skipped"            0 1.26.5 'FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine AS b'
t "non-Go image is not our business"      0 1.26.5 'FROM alpine:3.21'

# --- floating tags warn, never fail -----------------------------------------
# They build. A gate that fails what builds trains people to skip gates.
t "floating tag does not fail"            0 1.26.5 'FROM golang:1.26-alpine'
tmsg "floating tag warns" '::warning'       1.26.5 'FROM golang:1.26-alpine'
t "floating minor below floor IS refused" 1 1.26.5 'FROM golang:1.25-alpine'

# --- ARG resolution ---------------------------------------------------------
# A parameterised FROM is only as good as its default; check it, don't skip it.
t "ARG default below floor is refused"    1 1.26.5 'ARG GO_VERSION=1.26.4' 'FROM golang:${GO_VERSION}-bookworm'
t "ARG default at floor builds"           0 1.26.5 'ARG GO_VERSION=1.26.5' 'FROM golang:${GO_VERSION}-bookworm'
t "unbraced \$VAR resolves"                1 1.26.5 'ARG GO_VERSION=1.24' 'FROM golang:$GO_VERSION-bookworm'
t "ARG with trailing comment parses"      1 1.26.5 'ARG GO_VERSION=1.26.4 # keep in step' 'FROM golang:${GO_VERSION}-alpine'
# luxfi/node ships this literally, to silence a buildx warning on a Dockerfile
# that is never built with the default. It must not crash the gate.
t "unparseable ARG default is skipped"    0 1.26.5 'ARG GO_VERSION=INVALID # silences a warning' 'FROM golang:${GO_VERSION}-bookworm'
t "unversioned golang:alpine is skipped"  0 1.26.5 'FROM golang:alpine'
t "golang:1-alpine is skipped"            0 1.26.5 'FROM golang:1-alpine'

# --- module resolution ------------------------------------------------------
# Multi-module repos build subdirectories against their OWN go.mod. Taking the
# root's floor would report a mismatch that does not exist (or miss one that
# does) — hanzoai/s3 is the live case.
d="$tmp/multi"; mkdir -p "$d/sub"
printf 'module root\n\ngo 1.26.5\n' > "$d/go.mod"
printf 'module sub\n\ngo 1.24.0\n' > "$d/sub/go.mod"
printf 'FROM golang:1.24-alpine\n' > "$d/sub/Dockerfile"
out=$(cd "$d" && bash "$GOVER" sub/Dockerfile . 2>&1); rc=$?
if [ "$rc" = 0 ]; then printf 'ok    %-56s rc=0\n' "nearest go.mod wins over the root"
else printf 'FAIL  %-56s rc=%s\n      %s\n' "nearest go.mod wins over the root" "$rc" "$out"; fail=1; fi
printf 'FROM golang:1.24-alpine\n' > "$d/Dockerfile"
out=$(cd "$d" && bash "$GOVER" Dockerfile . 2>&1); rc=$?
if [ "$rc" = 1 ]; then printf 'ok    %-56s rc=1\n' "root Dockerfile is judged by the root go.mod"
else printf 'FAIL  %-56s rc=%s\n      %s\n' "root Dockerfile is judged by the root go.mod" "$rc" "$out"; fail=1; fi

# --- no module at all -------------------------------------------------------
d2="$tmp/nomod"; mkdir -p "$d2"
printf 'FROM golang:1.20-alpine\n' > "$d2/Dockerfile"
out=$(cd "$d2" && bash "$GOVER" Dockerfile . 2>&1); rc=$?
if [ "$rc" = 0 ]; then printf 'ok    %-56s rc=0\n' "no go.mod: nothing to compare, stays silent"
else printf 'FAIL  %-56s rc=%s\n      %s\n' "no go.mod: nothing to compare, stays silent" "$rc" "$out"; fail=1; fi

# --- the remediation is in the message --------------------------------------
# A gate that says only "no" costs the next person the same hour it cost the
# last one.
tmsg "error names the fix (pin + GOTOOLCHAIN=auto)" 'GOTOOLCHAIN=auto' 1.26.5 'FROM golang:1.26.4-alpine'
tmsg "error quotes the runtime failure it prevents" 'go.mod requires go >=' 1.26.5 'FROM golang:1.26.4-alpine'

# --- build context decides the module, not file location -------------------
# hanzoai/s3's live shape: a Dockerfile under test/kafka/ built with
# `context: ../..` that does `COPY go.mod go.sum ./` compiles the ROOT module.
# Judging it by test/kafka/go.mod reads 1.25.0 where the truth is 1.26.5 — the
# difference between "fine" and "cannot build".
d3="$tmp/ctxwins"; mkdir -p "$d3/test/kafka"
printf 'module root\n\ngo 1.26.5\n' > "$d3/go.mod"
printf 'module sub\n\ngo 1.25.0\n' > "$d3/test/kafka/go.mod"
printf 'FROM golang:1.25-alpine\nCOPY go.mod go.sum ./\nRUN go build ./...\n' > "$d3/test/kafka/Dockerfile.s3"
out=$(cd "$d3" && bash "$GOVER" test/kafka/Dockerfile.s3 . 2>&1); rc=$?
if [ "$rc" = 1 ]; then printf 'ok    %-56s rc=1\n' "context go.mod wins when Dockerfile COPYs it"
else printf 'FAIL  %-56s rc=%s\n      %s\n' "context go.mod wins when Dockerfile COPYs it" "$rc" "$out"; fail=1; fi
# ...and the converse: a subdir module built from its OWN directory as context,
# copying its OWN go.mod, is still judged by its own floor.
d4="$tmp/subctx"; mkdir -p "$d4/sidecar"
printf 'module root\n\ngo 1.26.5\n' > "$d4/go.mod"
printf 'module sidecar\n\ngo 1.24.0\n' > "$d4/sidecar/go.mod"
printf 'FROM golang:1.24-alpine\nCOPY go.mod go.sum ./\n' > "$d4/sidecar/Dockerfile"
out=$(cd "$d4/sidecar" && bash "$GOVER" Dockerfile . 2>&1); rc=$?
if [ "$rc" = 0 ]; then printf 'ok    %-56s rc=0\n' "own-directory context keeps its own floor"
else printf 'FAIL  %-56s rc=%s\n      %s\n' "own-directory context keeps its own floor" "$rc" "$out"; fail=1; fi
# A Dockerfile that copies a SUBDIRECTORY's go.mod is judged by the nearest one,
# not the context root — otherwise every multi-module repo reports false alarms.
d5="$tmp/nocopy"; mkdir -p "$d5/svc"
printf 'module root\n\ngo 1.26.5\n' > "$d5/go.mod"
printf 'module svc\n\ngo 1.24.0\n' > "$d5/svc/go.mod"
printf 'FROM golang:1.24-alpine\nCOPY svc/go.mod ./\n' > "$d5/svc/Dockerfile"
out=$(cd "$d5" && bash "$GOVER" svc/Dockerfile . 2>&1); rc=$?
if [ "$rc" = 0 ]; then printf 'ok    %-56s rc=0\n' "subdir go.mod copy is not the context root"
else printf 'FAIL  %-56s rc=%s\n      %s\n' "subdir go.mod copy is not the context root" "$rc" "$out"; fail=1; fi

echo
[ $fail = 0 ] && echo "all gover tests passed" || echo "gover tests FAILED"
exit $fail
