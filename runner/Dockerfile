# The runner image — our ubuntu-latest.
#
# `runs-on: ubuntu-latest` has to mean OUR machine, or it means GitHub's. There
# is no third option: the label is resolved by whoever owns the pool, so the way
# to stop renting builders is to serve the label ourselves.
#
# It runs under the `host` executor inside a Firecracker guest, which is why the
# toolchain lives HERE rather than in a per-job container: the VM is the sandbox,
# and a nested runtime would only be a second, weaker one. So this image is what
# a job sees, and it carries what a job actually reaches for -- git, build
# essentials, node, python, docker CLI, and the `hanzo` CLI so a workflow can
# talk to the cloud it is being built for.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git jq unzip zip xz-utils gnupg \
      build-essential pkg-config \
      python3 python3-pip python3-venv \
      openssh-client rsync sudo tini \
 && rm -rf /var/lib/apt/lists/*

# Node via nodesource: workflows assume a current node, and the distro's is old.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm i -g pnpm@10 yarn \
 && rm -rf /var/lib/apt/lists/*

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

# act_runner: the agent that claims jobs from the forge.
ARG ACT_RUNNER_VERSION=0.2.13
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) a=amd64 ;; arm64) a=arm64 ;; *) echo "unsupported $arch" >&2; exit 1 ;; esac; \
    curl -fsSL -o /usr/local/bin/act_runner \
      "https://gitea.com/gitea/act_runner/releases/download/v${ACT_RUNNER_VERSION}/act_runner-${ACT_RUNNER_VERSION}-linux-${a}"; \
    chmod +x /usr/local/bin/act_runner; \
    act_runner --version

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
 && mkdir -p /data "$RUNNER_TOOL_CACHE" && chown -R runner:runner /data "$RUNNER_TOOL_CACHE"

USER runner
WORKDIR /data
RUN chown -R runner:runner /opt/actions-runner
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/runner"]
