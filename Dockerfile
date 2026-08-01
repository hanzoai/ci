# syntax=docker/dockerfile:1
#
# ci — the ci.hanzo.ai dashboard. Pure-Go, no cgo, no node: the page is
# server-rendered from a template compiled into the binary, and the design
# tokens it spends are @hanzo/brand's published stylesheet, go:embed-ed beside
# it. So the image is still the binary and a CA bundle — nothing served from
# disk, nothing to go stale against the code, and no JS toolchain on the path
# that ships the board you read when the builds are broken.
FROM golang:1.26.5-alpine AS builder
WORKDIR /build
# Resolve through the module proxy: proxy.golang.org and sum.golang.org agree
# and neither can change under us, which a direct fetch against a moved tag
# cannot promise.
ENV GOPROXY=https://proxy.golang.org,direct
# The base image above is pinned to exactly the Go go.mod asks for, so nothing
# is downloaded here — the pin is what makes this build hermetic. GOTOOLCHAIN
# is set to auto anyway, because the golang images default it to `local` and
# that turns the NEXT go.mod bump from "fetches the toolchain it needs" into
# "dies mid-build with go.mod requires go >= X". The pin is the fast path; this
# is the one that keeps a version bump from being a build break. bin/gover
# gates the same rule for every repo this pipeline builds.
ENV GOTOOLCHAIN=auto
COPY go.mod ./
RUN --mount=type=cache,id=ci-gomod,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,id=ci-gomod,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /build/ci .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S hanzo && adduser -S hanzo -G hanzo
COPY --from=builder /build/ci /app/ci
USER hanzo
EXPOSE 8080
# Liveness only. Readiness deliberately does not gate on having a snapshot — see
# the /healthz comment in main.go: a Hanzo Git outage must render as a dashboard
# saying so, not as this pod leaving the load balancer as well.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/app/ci"]
