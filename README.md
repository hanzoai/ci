<p align="center"><img src=".github/hero.svg" alt="ci" width="880"></p>

# hanzoai/ci

One reusable CI/CD workflow for every Hanzo / Lux / Zoo repo. Build + test +
publish, driven entirely by the repo's root **`hanzo.yml`**. No per-repo build
logic — repos import this and declare their specifics in `hanzo.yml`.

A build ends at a published image. What RUNS is declared in `hanzo/universe`,
and cd.hanzo.ai applies that within one poll — see [Deploying](#deploying).

**ci.hanzo.ai** is this repo's other half: the dashboard that shows what the
pipeline did — see [The fleet view](#the-fleet-view).

## The fleet view

`ci.hanzo.ai` answers one question per service: **is what we wrote what is
running?** Four values answer it, and they are one causal line rather than four
opinions:

```
head ──build──▶ built ──pin──▶ declared ──reconcile──▶ running
```

| value | read from | means |
|---|---|---|
| **head** | the repo's default branch | what we wrote |
| **built** | the newest commit whose run produced an image | what we proved |
| **declared** | `charts/app/values/<ns>/<name>.yaml` in `hanzo/universe` | what CD was told to run |
| **running** | the workload's image in the cluster, by digest | what serves traffic |

Every arrow is a job of the pipeline above, so a service is current exactly when
all four agree, and each way they disagree names the arrow that did not happen:

- `unbuilt` — head produced no image. Counted only once a build has STOPPED
  without one, so a push in flight is not drift.
- `unshipped` — an image was proved that the pin never named.
- `unsynced` — the pin and the cluster disagree, compared by digest.
- `untested` — a passing build whose tests did not execute.

Three matching values are not health, which is why head is read at all: built,
declared and running can agree perfectly while main has moved on and nothing
since has built.

Two readings the page depends on, both from a run's JOBS rather than its one
conclusion. A run that fails at `gate` built nothing; a run that fails at
`receipt` has already built, pinned and proved the release live. Both report
`failure`. And a commit Hanzo Git never constructed a run for is `absent`, not
failed — there is no log to open, so it is drawn as a different shape.

It reads and never writes: no deploy, no retry, no promotion. Drive a sync at
cd.hanzo.ai.

### What it needs

`ci` reads the cluster through its own ServiceAccount — get and list on
workloads, nothing else, no stored credential — and reads `hanzo/universe`
through the Hanzo Git token it already holds. In `charts/app/values/hanzo/ci.yaml`:

```yaml
rbac:
  create: true
  clusterRules:
    - apiGroups: ["apps"]
      resources: ["deployments", "statefulsets", "daemonsets"]
      verbs: ["get", "list"]
```

| env | default | |
|---|---|---|
| `CI_UNIVERSE` | `hanzo/universe` | repo holding the declared state |
| `CI_FLEET_SECONDS` | `300` | how often the four values are re-read |

## Use it

A repo needs two files. First, `hanzo.yml` at the root (the config):

```yaml
images:
  - { name: api, context: ./api, repo: ghcr.io/<org>/<repo>, tag-suffix: api }
test:
  - { name: api, run: "pytest -q" }
kms: { path: /deploy, environment: prod }
```

Second, a ~7-line `.hanzo/workflows/cicd.yml` that just imports this:

```yaml
name: CI/CD
on:
  push: { branches: [main], tags: ["v*"] }
  pull_request:
  workflow_dispatch:
jobs:
  cicd:
    uses: hanzoai/ci/.hanzo/workflows/build.yml@v1
    secrets: inherit
```

That's it. The build/test/publish logic lives here, once.

### `.hanzo/workflows/`, and nothing left in `.github/workflows/`

Hanzo Git collects workflows from the **first** entry of `WORKFLOW_DIRS` that
exists — not the union. So the moment one file lands in `.hanzo/workflows/`,
every remaining file under `.github/workflows/` stops running. It stops
*silently*: the checks that would go red are the ones no longer running, so the
repo reports green over a pipeline that is not there. A half-finished migration
runs neither lane.

Find them in any repo:

```bash
comm -23 <(ls .github/workflows) <(ls .hanzo/workflows)   # anything listed is dead
```

Moving a file is not reviving it. Two things break on the way across:

- **`runs-on: ubuntu-latest` matches no runner in this fleet**, deliberately —
  Hanzo Git hosts ~1400 mirrored repos whose upstream workflows all ask for it,
  and advertising it hands the fleet to their CI. An unmatched label does not
  fail, it **queues until the timeout**. Use `hanzo-build-linux-amd64`, or
  another label declared in the `git-runner-config` ConfigMap (ns `hanzo`).
- **Anything reading a GitHub-only surface** — `github.event.pull_request`, PR
  comments, GH Releases, the compare API, GH App tokens, CodeQL's
  `security-events` upload, OIDC trusted publishing — has no equivalent here and
  must be ported deliberately or dropped and said out loud.

In a fork, most files under `.github/workflows/` are the *upstream project's*
CI: PR labelers, reviewer assignment, stale bots, and release trains for
packages we do not publish. Moving those runs someone else's automation on our
fleet. Sort every file into revive / rewrite / drop, then **delete the
directory** — a dead file cannot accumulate in a directory that does not exist.

## Deploying

This workflow does not deploy. It builds an image and publishes it.

What runs in a cluster is declared in `hanzo/universe`, which cd.hanzo.ai reads:

- Helm services — `charts/app/values/<ns>/<svc>.yaml` (`image.tag`, and
  `image.digest`, which wins over the tag when both are set)
- plain manifests — e.g. `infra/k8s/monitoring/<svc>.yaml`

Change the declaration and cd applies it within one poll. The cluster enforces
this: a `ValidatingAdmissionPolicy` named `cd-owns-the-fleet` rejects a direct
edit, whoever makes it.

  This cluster is reconciled, not edited. A workload changes by changing what
  DECLARES it — the values file cd.hanzo.ai reads — and cd applies it within
  one poll.

## `client:` — one document, eight generated clients

A generated SDK is a **projection** of one API document at one version. This lane
is the only place in the fleet that says how a projection is made, so the eight
client repos (`python-sdk`, `js-sdk`, `go-sdk`, `rust-sdk`, `java-sdk`,
`kotlin-sdk`, `cpp-sdk`, `cli`) stop carrying eight copies of the same eight
lines.

```yaml
client:
  spec: { repo: hanzo-inc/cloud, path: openapi.yaml }  # these are the defaults
  generate: ./scripts/generate.sh        # $SPEC is the fetched document
  version:  'package.json:jq -r .version package.json'   # optional; see below
```

There is deliberately **no `build:`**. The repo already declared how it proves
itself, in `test:`, and that block runs over the regenerated tree — which is
exactly the gate. A second declaration would be one assertion written twice.

It fires on `repository_dispatch: spec-update`, which **hanzoai/cloud sends once
per release**:

```yaml
on:
  repository_dispatch: { types: [spec-update] }
  workflow_dispatch:
```

The coupler is the document, **passed by value at a pinned ref**. The payload
carries `(version, sha, spec_sha256)`; the lane fetches `openapi.yaml` at that
sha and refuses if the bytes hash to anything else — every projection of one
release is generated from one digest. Reading a live host instead would be a lie
about which deploy the client describes.

Three gates, in order:

| gate | refuses |
|---|---|
| digest | a client generated from a different document than its siblings |
| `test:` | a spec change that produces a client which does not compile — **including its examples** |
| `.spec-lock` | is committed beside the code: `ref` + `sha256`, so anyone can ask a client repo *which document are you?* without running a generator |

On a delta — and only after `test:` has passed over exactly those bytes — the
lane commits the projection, bumps the **patch** (derived, never typed: a
projection never earns a minor or a major) and pushes the tag. The repo's own tag
lane publishes it, so the registry credential stays where the publish is.

`version:` says **where this client's version lives**, because that answer is
genuinely different per language:

| value | meaning |
|---|---|
| `"<file>:<command printing it>"` | it lives in a file — rewrite it, commit, tag |
| `tag` | the tag **is** the version (a Go module has nothing to rewrite) |
| absent | CI cannot derive one — the projection is committed and gated, nothing is cut |

The third state is not a gap to fill later. A repo whose version is not `x.y.z`
(a `-alpha.N` gradle build) has no patch for this lane to derive, and guessing
one would tag bytes under a number nobody chose.

Credential: **`SPEC_TOKEN`** — a fine-grained token with `contents:read` on the
spec repo.

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

Add a top-level `bucket:` and they publish to **hanzoai/s3** instead — same
artifacts, same index, only the url changes:

```yaml
bucket: plugins   # → https://s3.hanzo.ai/plugins/<owner>/<repo>/<tag>/binaries.json
```

Credentials are the `S3_ADMIN_*` names the services already read, pulled from
KMS at run time; a declared bucket with no credential fails the publish rather
than shipping an index whose artifacts are missing. Use it for anything large or
frequent — a GitHub release stores it on a quota we do not own.

Builds are `CGO_ENABLED=0 -trimpath`: the host that installs this runs it on
whatever base image the host is, and the digest must be a function of the
source, not of the checkout path.

## `site:` — a static export, promoted to an immutable release

`images:` ships an OCI image a **cluster** runs; `binaries:` ships an executable
a **host** installs. `site:` ships a static export an **edge** serves — no image,
no CR, no replicas. Building a container so a Go binary can serve `/public` is
the shape this retires.

```yaml
site:
  slug: hanzo-console         # the project on the Sites plane
  dir: out                    # the built export; needs index.html at its root
  build: npm ci && npm run build   # optional; run first
  on: [main]                  # branch gate; tags always publish
```

That is the whole configuration. **There is no credential to provision**: the
bearer is the IAM JWT the workflow already mints from `KMS_CLIENT_ID` /
`KMS_CLIENT_SECRET`, so a repo that can build can publish. CI names no bucket and
no org — the org segment is prepended server-side from the validated principal,
which is what makes the prefix unforgeable.

The export ships through [`bin/site`](bin/site):
`POST /v1/projects/<slug>/deployments` answers with a prefix-scoped, 30-minute
presigned grant, every file goes straight to S3 against it, and the completion
carries the manifest cloud reconciles the prefix against — deleting whatever the
build no longer produces. CI never holds a bucket key.

**One size boundary, and it is the server's.** cloud's public edge caps a request
body at 16 MiB (`GATEWAY_BODY_LIMIT`, `internal/edge/edge.go`) and refuses a
larger POST before any handler runs — answering only `Error when parsing
request`, which names neither size nor cause. So every body either lane posts is
measured against that number *first* and refused *with* it, and the size is
printed on every publish whether or not it is near the limit:

```
release: 116.2 MiB / 627 files; manifest 13.5 KiB of the 16.0 MiB edge limit
```

The release bytes are not what the edge bounds here — they stream per file. What
it bounds is the completion manifest, which grows with the object **count**, so
a full prerender is what walks a site toward the cap. Measured before the
enqueue, so a refusal costs nothing and leaves no deployment open.

[`bin/sitepublish`](bin/sitepublish) is the other transport, and there the zip is
the body, so the cap lands on it directly: it posts the export whole to
`/v1/projects/<slug>/deploy` and promotes it via `/v1/sites/<slug>/publish` into
an **immutable release** whose id digests its object manifest, then re-reads the
release list and refuses unless the release it just published is the one that is
live. Rollback is the same pointer aimed at an older release. Of the 24 built
exports in the estate 22 fit that body; the two that do not (`hanzo.ai`, 27.9 MiB
zipped over 8,536 files, and `trillerfest.com` at 76.7 MiB) can only stream —
`hanzo.ai` is past the server's own 5,000-entry release cap besides.

## Runners — our fleet or your own

By default the build runs on the **Hanzo `git-runner` fleet** on git.hanzo.ai
(we run it; metered as build minutes) — the only pool that serves the default
`hanzo-build-linux-amd64` label. There is no arc pool: arc (arcd) was retired
2026-08-01 and never served any label in this default. To run on **your own**
self-hosted runners, pass their labels:

```yaml
    uses: hanzoai/ci/.hanzo/workflows/build.yml@v1
    with:
      runner: '["self-hosted","my-pool","linux","amd64"]'
    secrets: inherit
```

## Delegate the build (skip runner buildx)

By default the build runs buildx **on** the runner. To instead hand the build to
the fabric's build door — `POST /v1/runner` on **api.hanzo.ai**, which launches a
BuildKit Job in-cluster and pushes the image — pass `mode: delegate`:

```yaml
    uses: hanzoai/ci/.hanzo/workflows/build.yml@v1
    with:
      mode: delegate
    secrets: inherit
```

The job gates the commit exactly as it always does, then POSTs each image in
`hanzo.yml` to that one door and exits in **seconds** — no runner buildx, no
runner-side publish, no runner-side deploy. It is the same door this pipeline
already names as the publisher for `binaries:`, and it needs **no secret of its
own**: it presents this org's IAM identity, which the KMS login in the same job
already mints from `KMS_CLIENT_ID` / `KMS_CLIENT_SECRET`. The build states the
repository, the commit this run gated, the output image and the Dockerfile; the
organization is the door's to read off that identity, so there is no field for
one and nothing for a caller to get wrong.

Three declarations the door cannot express, and the lane refuses each before it
POSTs rather than publishing an image that is not the one the repo asked for:
`build_secrets` (it mounts no KMS), a `context` below the repository root (its
context is the whole repository at one commit), and a `platforms` list that is
anything but `linux/amd64`.

`mode: buildx` (the default) is unchanged — existing repos keep running buildx on
the fleet runner, so delegation is strictly opt-in.

## Credentials

The only GitHub secrets a repo sets are `KMS_CLIENT_ID` / `KMS_CLIENT_SECRET`
(plus the `KMS_WORKSPACE` repo variable). Everything else — the GHCR push token,
the cluster kubeconfig, `HANZO_GIT_TOKEN` — is pulled from KMS (`kms.hanzo.ai`,
Universal Auth) at run time. No long-lived registry or cluster credentials live
in GitHub.

`HANZO_GIT_TOKEN` is git.hanzo.ai's, and only the reads the per-job token cannot
serve name it: a private repo this run does not belong to (`hanzoai/openapi`, a
sibling Go module) and the client lane's push past a protected branch. Everything
else on that host — the tools clone of public `hanzoai/ci` — rides the per-job
token and needs nothing sealed. It is not interchangeable with `GIT_TOKEN`, which
is github.com's.

## Platform-native

`hanzo.yml` is also read by platform.hanzo.ai: a repo on the platform webhook
needs **only** `hanzo.yml` — the platform builds it in-cluster and rolls it out, no
workflow file at all. This reusable is the GitHub-Actions path for repos that
trigger through GitHub instead of the platform.
