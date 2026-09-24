# The runner image — our ubuntu-latest.
#
# `runs-on: ubuntu-latest` has to mean OUR machine, or it means GitHub's. There
# is no third option: the label is resolved by whoever owns the pool, so the way
# to stop renting builders is to serve the label ourselves.
#
# It runs under the `host` executor inside the visor sandbox, which is why the
# toolchain lives HERE rather than in a per-job container: the sandbox is the
# boundary, and a nested runtime would only be a second, weaker one. So this
# image is what a job sees, and it carries what a job actually reaches for --
# git, build essentials, node, python, docker CLI, and the `hanzo` CLI so a
# workflow can talk to the cloud it is being built for.
#
# Nothing can be installed at job time. visor ignores the setuid bit unless the
# node runs it with --allow-suid, which it does not, so `sudo` starts as the
# runner and answers "effective uid is not 0, is /usr/bin/sudo on a file system
# with the 'nosuid' option set" -- the message guesses the cause, and the guess
# is wrong. Whatever a job needs has to be in this file.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    COREPACK_HOME=/opt/corepack

# The toolchain the reusable build asks for at job time. A job cannot install
# it: `sudo apt-get` answers "effective uid is not 0" (see the top of this file)
# and the step exits 1 — which is how every repo with a `client:` lane went red. build.yml already guards each of those
# steps with `command -v javac`, `pkg-config --exists openssl` and a libclang
# lookup, so carrying the packages here makes all of them no-ops.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git jq unzip zip xz-utils gnupg \
      build-essential pkg-config libssl-dev libclang-dev \
      openjdk-21-jdk-headless \
      python3 python3-pip python3-venv \
      openssh-client rsync sudo tini procps zstd \
 && rm -rf /var/lib/apt/lists/*

# The OTHER architecture's C toolchain. gVisor builds the VDSO for both
# architectures in one bazel invocation, so building it on amd64 needs
# aarch64-linux-gnu-gcc and on arm64 needs x86_64-linux-gnu-gcc — and the
# visor publish lane failed on exactly that, with no way to add it at job time.
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) pkgs="gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libc6-dev-arm64-cross" ;; \
      arm64) pkgs="gcc-x86-64-linux-gnu g++-x86-64-linux-gnu libc6-dev-amd64-cross" ;; \
      *) echo "unsupported $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    apt-get update && apt-get install -y --no-install-recommends $pkgs \
 && rm -rf /var/lib/apt/lists/*

# Node and Go live in the tool cache, laid out exactly as actions/setup-node and
# actions/setup-go lay out what they download: <tool>/<version>/<arch> beside an
# <arch>.complete marker. So `setup-node: 22` and a go.mod naming 1.27.1 find
# them there and fetch nothing; before, every job downloaded both, 110 runner
# minutes in 48 hours. A job that asks for another version still downloads it.
# The act runner reads its tool cache from ~/.cache/act/tool_cache, which is
# linked here further down, so both runners see the same one.
ARG NODE_VERSION=22.23.3
ARG NODE_SHA256_AMD64=df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de
ARG NODE_SHA256_ARM64=a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) a=x64;   sum="$NODE_SHA256_AMD64" ;; \
      arm64) a=arm64; sum="$NODE_SHA256_ARM64" ;; \
      *) echo "unsupported $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    d="$RUNNER_TOOL_CACHE/node/$NODE_VERSION/$a"; mkdir -p "$d"; \
    curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$a.tar.xz"; \
    echo "$sum  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C "$d" --strip-components=1; rm /tmp/node.tar.xz; \
    touch "$d.complete"; ln -s "$d" /opt/node
ENV PATH=/opt/node/bin:$PATH

# pnpm and yarn through corepack, which reads the version a repo pins in
# packageManager. The pnpm versions the fleet pins are fetched once here, so a
# job's `corepack enable` finds them; 10.x is the default for a repo that pins
# none, as the global `pnpm@10` it replaces was.
RUN set -eux; \
    corepack enable; \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack install -g pnpm@11.24.0; \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack install -g yarn@1.22.22; \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack install -g pnpm@10.16.1; \
    pnpm --version; yarn --version

ARG GO_VERSION=1.27.1
ARG GO_SHA256_AMD64=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445
ARG GO_SHA256_ARM64=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) a=x64;   g=amd64; sum="$GO_SHA256_AMD64" ;; \
      arm64) a=arm64; g=arm64; sum="$GO_SHA256_ARM64" ;; \
      *) echo "unsupported $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    d="$RUNNER_TOOL_CACHE/go/$GO_VERSION/$a"; mkdir -p "$d"; \
    curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go$GO_VERSION.linux-$g.tar.gz"; \
    echo "$sum  /tmp/go.tgz" | sha256sum -c -; \
    tar -xzf /tmp/go.tgz -C "$d" --strip-components=1; rm /tmp/go.tgz; \
    touch "$d.complete"; ln -s "$d" /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH

# helm, which the universe deploy lanes call. Their install script copies the
# binary into /usr/local/bin with sudo, which cannot work here; with helm already
# at the version it would install, it has nothing to do.
ARG HELM_VERSION=v3.22.0
ARG HELM_SHA256_AMD64=1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb
ARG HELM_SHA256_ARM64=f14e804dfee240f55525b667488fe9adca349e63e00c9af634c0beb1421ac310
RUN set -eux; \
    g="$(dpkg --print-architecture)"; \
    case "$g" in amd64) sum="$HELM_SHA256_AMD64" ;; arm64) sum="$HELM_SHA256_ARM64" ;; *) exit 1 ;; esac; \
    curl -fsSL -o /tmp/helm.tgz "https://get.helm.sh/helm-$HELM_VERSION-linux-$g.tar.gz"; \
    echo "$sum  /tmp/helm.tgz" | sha256sum -c -; \
    tar -xzf /tmp/helm.tgz -C /tmp "linux-$g/helm"; \
    install -m0755 "/tmp/linux-$g/helm" /usr/local/bin/helm; rm -rf /tmp/helm.tgz "/tmp/linux-$g"; \
    helm version --short

# crane, which the delegate lane uses to read back and tag what the build door
# pushed, and which it used to download on every run.
ARG CRANE_VERSION=v0.20.2
RUN set -eux; \
    case "$(dpkg --print-architecture)" in amd64) a=x86_64 ;; arm64) a=arm64 ;; *) exit 1 ;; esac; \
    curl -fsSL "https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_Linux_$a.tar.gz" \
      | tar -xz -C /usr/local/bin crane; \
    crane version

# bun, system-wide: the JS repos install with it, and a per-job setup action
# cannot put a binary on the PATH of a step that runs in the same guest.
ARG BUN_VERSION=1.3.9
RUN curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-$(dpkg --print-architecture | sed 's/amd64/x64/;s/arm64/aarch64/').zip" -o /tmp/bun.zip \
 && unzip -q /tmp/bun.zip -d /tmp && install -m0755 /tmp/bun-linux-*/bun /usr/local/bin/bun && ln -sf bun /usr/local/bin/bunx \
 && rm -rf /tmp/bun.zip /tmp/bun-linux-* && bun --version

# The docker CLI only. There is no daemon in here on purpose -- a job that wants
# to build an image asks the platform builder, which is the one build path.
RUN install -m0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

# git-runner: the agent that claims jobs from Hanzo Git. The binary is Gitea's
# act_runner release, installed under the name this estate calls it.
ARG RUNNER_VERSION=0.2.13
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) a=amd64 ;; arm64) a=arm64 ;; *) echo "unsupported $arch" >&2; exit 1 ;; esac; \
    curl -fsSL -o /usr/local/bin/git-runner \
      "https://gitea.com/gitea/act_runner/releases/download/v${RUNNER_VERSION}/act_runner-${RUNNER_VERSION}-linux-${a}"; \
    chmod +x /usr/local/bin/git-runner; \
    git-runner --version

# The hanzo CLI, so a job can reach the cloud it builds for rather than
# re-implementing a piece of it in shell.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) a="$arch" ;; esac; \
    curl -fsSL "https://hanzo.ai/install.sh" -o /tmp/hanzo-install.sh 2>/dev/null \
      && sh /tmp/hanzo-install.sh || echo "hanzo CLI: install script unavailable at build time"; \
    rm -f /tmp/hanzo-install.sh

# GitHub's own runner, for a job GitHub queues: it registers with the one-job
# configuration the cloud minted (--jitconfig) and exits when that job is done.
ARG ACTIONS_RUNNER_VERSION=2.337.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) a=x64 ;; arm64) a=arm64 ;; *) echo "unsupported $arch" >&2; exit 1 ;; esac; \
    mkdir -p /opt/actions-runner && cd /opt/actions-runner; \
    curl -fsSL -o runner.tgz "https://github.com/actions/runner/releases/download/v${ACTIONS_RUNNER_VERSION}/actions-runner-linux-${a}-${ACTIONS_RUNNER_VERSION}.tar.gz"; \
    tar xzf runner.tgz && rm runner.tgz; \
    ./bin/installdependencies.sh && rm -rf /var/lib/apt/lists/*

# Playwright's chromium and the libraries it needs, at the version the site
# repos pin, live in the image: `playwright install chromium` at job time is a
# no-op, and `--with-deps` (which runs apt against whatever source a job added
# to the guest) is unnecessary.
ARG PLAYWRIGHT_VERSION=1.58.0
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN npx -y playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium \
 && chmod -R a+rX /opt/playwright \
 && rm -rf /var/lib/apt/lists/* /root/.npm /root/.cache

# One entrypoint, two registrations: the environment says which system queued
# the job, and the runner that claims it lives exactly one job.
COPY --chmod=0755 runner /usr/local/bin/runner

RUN useradd -m -u 1001 -s /bin/bash runner \
 && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
 && mkdir -p /data "$RUNNER_TOOL_CACHE" /home/runner/.cache/act \
 && ln -s "$RUNNER_TOOL_CACHE" /home/runner/.cache/act/tool_cache \
 && chown -R runner:runner /data "$RUNNER_TOOL_CACHE" "$COREPACK_HOME" /home/runner/.cache

USER runner
WORKDIR /data
RUN chown -R runner:runner /opt/actions-runner
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/runner"]
