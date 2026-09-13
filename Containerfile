# syntax=docker/dockerfile:1
#
# copilot-container image: Ubuntu-based dev environment with GitHub Copilot
# CLI, a common toolchain (go/java/python3/unix utils/git/gh/glab/
# markdownlint) and the Hunk CLI client preinstalled.
#
# Build (Podman, preferred):
#   podman build -t copilot-container .
#
# Build (Docker):
#   docker build -t copilot-container .
#
# Bump the pinned Copilot CLI version:
#   podman build --build-arg COPILOT_CLI_VERSION=X.Y.Z -t copilot-container .

FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

# ---- Pinned tool versions ----------------------------------------------
ARG COPILOT_CLI_VERSION=1.0.83
ARG HUNK_VERSION=0.22.0
ARG NODE_MAJOR=22
ARG MARKDOWNLINT_CLI_VERSION=0.49.1

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---- Base OS packages + common dev toolchain ----------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        git make sed gawk grep ripgrep \
        golang-go \
        openjdk-21-jdk-headless \
        python3 python3-pip python3-venv \
        unzip xz-utils tar less nano vim \
        gosu glab \
    && rm -rf /var/lib/apt/lists/*

# ---- Node.js (required by Copilot CLI + markdownlint-cli) ---------------
# Ubuntu's own nodejs package is too old; add NodeSource's apt repo directly
# (key + sources file) instead of piping their setup script to bash.
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && chmod 644 /usr/share/keyrings/nodesource.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI (gh) ------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---- Hunk CLI client (talks to the host's Hunk loopback daemon only; the
#      Hunk TUI itself always runs on the host) - no apt package upstream,
#      so verify the release tarball against its published SHA256SUMS. ----
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) hunk_arch=x64 ;; \
        arm64) hunk_arch=arm64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    workdir="$(mktemp -d)"; \
    cd "${workdir}"; \
    curl -fsSL -O "https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/hunkdiff-linux-${hunk_arch}.tar.gz"; \
    curl -fsSL -O "https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/SHA256SUMS"; \
    grep " hunkdiff-linux-${hunk_arch}.tar.gz\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "hunkdiff-linux-${hunk_arch}.tar.gz" --strip-components=1; \
    install -m 0755 hunk /usr/local/bin/hunk; \
    cd /; rm -rf "${workdir}"

# ---- Copilot CLI (pinned) + markdownlint ---------------------------------
RUN npm install -g "@github/copilot@${COPILOT_CLI_VERSION}" \
        "markdownlint-cli@${MARKDOWNLINT_CLI_VERSION}" \
    && npm cache clean --force

# ---- Entrypoint ------------------------------------------------------------
COPY lib/entrypoint.sh /usr/local/bin/copilot-container-entrypoint
RUN chmod +x /usr/local/bin/copilot-container-entrypoint

# A non-root home dir template; entrypoint creates/aligns the actual runtime
# user's home at container start based on HOST_UID/HOST_GID.
RUN mkdir -p /home/copilot && chmod 0755 /home/copilot

ENTRYPOINT ["/usr/local/bin/copilot-container-entrypoint"]
CMD ["copilot"]
