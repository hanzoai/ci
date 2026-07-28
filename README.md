<p align="center"><img src=".github/hero.svg" alt="ci" width="880"></p>

# hanzoai/ci

One reusable CI/CD workflow for every Hanzo / Lux / Zoo repo. Build + test +
deploy, driven entirely by the repo's root **`hanzo.yml`**. No per-repo build
logic — repos import this and declare their specifics in `hanzo.yml`.

## Use it

A repo needs two files. First, `hanzo.yml` at the root (the config):

```yaml
images:
  - { name: api, context: ./api, repo: ghcr.io/<org>/<repo>, tag-suffix: api }
test:
  - { name: api, run: "pytest -q" }
deploy:
  cluster: <cluster>
  namespace: <ns>
  on: [main]
  services:
    - { name: <deployment>, image: api }
kms: { path: /deploy, environment: prod }
```

Second, a ~7-line `.github/workflows/cicd.yml` that just imports this:

```yaml
name: CI/CD
on:
  push: { branches: [main], tags: ["v*"] }
  pull_request:
  workflow_dispatch:
jobs:
  cicd:
    uses: hanzoai/ci/.github/workflows/build.yml@v1
    secrets: inherit
```

That's it. The build/test/deploy logic lives here, once.

## `binaries:` — publish a plugin once, install it everywhere

`images:` ships an OCI image a **cluster** runs. `binaries:` ships an
executable a **running host** installs: a [zip](https://github.com/zap-proto/zip)
plugin, fetched at run time by URL and verified against its SHA-256 before it is
ever made executable. Build it once per OS/arch here; every host picks up the
same bits, and nobody rebuilds the world to ship a plugin.

```yaml
binaries:
  - name: billing
    main: ./cmd/billing              # the Go package; default "."
    platforms: [linux/amd64, linux/arm64]   # default [linux/amd64]
    ldflags: "-s -w"                 # default
```

`main:` is the zero-config **Go** lane. Every other toolchain uses the same block
with `run:` (the command that builds) and `out:` (the glob of what it produced) —
which is how a repo with no Dockerfile and no Go still publishes an artifact:

```yaml
binaries:
  - name: sdk
    run: npm install && npm run build && npm pack --pack-destination .
    out: "*.tgz"
    image: node:22-bookworm          # the toolchain — see below
```

`image:` names the container the **platform** lane runs `run:` in
(`POST /v1/runner`, one initContainer per entry, in-cluster). Here the toolchain
IS the runner, so this workflow reads past it. It is not a second recipe: both
lanes read the same `binaries:` block out of the same `hanzo.yml` and publish the
same `binaries.json` at the same URL.

Artifacts land under `<name>` in the index regardless of lane; a `run:` entry is
`os: any, arch: any`, because an npm tarball or a wheel is not per-platform and
an index entry that claimed one would be a lie a host acts on.

Built on every push (an arm64 cross-compile that breaks fails the PR that broke
it) and **published on a tag**, after the `test:` gate — a host installs an
artifact unattended, so the tests gate the bits. Each artifact lands on the
GitHub Release for that tag:

```
https://github.com/<owner>/<repo>/releases/download/<tag>/<name>-<os>-<arch>
```

plus `binaries.json` beside them — `{name, os, arch, url, sha256}` for every
artifact, so the bits and the digest that authorizes them ship as one release
and a host reads both from one place. The job summary prints the
`zip.Load(zip.Plugin{URL, Sum})` a host pastes.

Builds are `CGO_ENABLED=0 -trimpath`: the host that installs this runs it on
whatever base image the host is, and the digest must be a function of the
source, not of the checkout path.

## Runners — our cloud or your own

By default the build runs on the **Hanzo cloud** arc pool (we run it; metered as
build minutes). To run on **your own** self-hosted arc runners, pass their labels:

```yaml
    uses: hanzoai/ci/.github/workflows/build.yml@v1
    with:
      runner: '["self-hosted","my-pool","linux","amd64"]'
    secrets: inherit
```

## Delegate to platform (skip runner buildx)

By default the build runs buildx **on** the arc runner. To instead hand the build
to **platform.hanzo.ai** — which builds in-cluster with BuildKit and rolls the
service itself — pass `mode: delegate`:

```yaml
    uses: hanzoai/ci/.github/workflows/build.yml@v1
    with:
      mode: delegate
    secrets: inherit
```

The GitHub job then just POSTs each image in `hanzo.yml` to platform's direct
build webhook (`/v1/arcd/enqueue`) and exits in **seconds** — no runner buildx,
no KMS, no runner-side deploy. Platform creates the build job, launches an
in-cluster BuildKit Job on its own pool, pushes to the registry, and patches the
operator `Service` CR to roll it. It's the same build path as the platform
GitHub-App webhook — one build path, two front doors.

Requires one extra secret, `PLATFORM_BUILD_CALLBACK_TOKEN` (org- or repo-level,
picked up via `secrets: inherit`). Override the endpoint with the
`PLATFORM_ENQUEUE_URL` repo/org variable (default `https://platform.hanzo.ai/v1/arcd/enqueue`).

`mode: buildx` (the default) is unchanged — existing repos keep running buildx on
arc, so delegation is strictly opt-in.

## Credentials

The only GitHub secrets a repo sets are `KMS_CLIENT_ID` / `KMS_CLIENT_SECRET`
(plus the `KMS_WORKSPACE` repo variable). Everything else — the GHCR push token,
the cluster kubeconfig — is pulled from KMS (`kms.hanzo.ai`, Universal Auth) at
run time. No long-lived registry or cluster credentials live in GitHub.

## Platform-native

`hanzo.yml` is also read by platform.hanzo.ai: a repo on the platform webhook
needs **only** `hanzo.yml` — the platform builds it on arc and rolls it out, no
workflow file at all. This reusable is the GitHub-Actions path for repos that
trigger through GitHub instead of the platform.
