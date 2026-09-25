# syntax=docker/dockerfile:1
#
# copilot-container image: Ubuntu-based dev environment with GitHub Copilot
# CLI, a common toolchain (unix utils/git/gh/glab/mado) and asdf (for
# per-project language/tool provisioning) preinstalled, plus the Hunk CLI
# client.
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
ARG COPILOT_CLI_VERSION=1.0.88
ARG HUNK_VERSION=0.22.0
ARG MADO_VERSION=0.3.2
ARG ASDF_VERSION=0.20.2

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---- Bootstrap: minimal tools needed to add third-party apt repos -------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# ---- Third-party apt repos (added before the main install so everything
#      else installs in a single `apt-get update` + `install` pass) --------
# GitHub CLI (gh)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list

# ---- Base OS packages + common dev toolchain (single update+install) ----
# Language/tool runtimes (Node, Go, Java, Python, Terraform/OpenTofu, ...)
# are deliberately not installed here: they're provisioned per-project via
# asdf (see below and the first-run setup script), so each project pins
# exactly the versions it needs instead of sharing one global version baked
# into the image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make sed gawk grep ripgrep \
        unzip xz-utils tar less nano vim \
        jq shellcheck \
        glab openssh-server \
        gh \
    && rm -rf /var/lib/apt/lists/*

# ---- Resolve the target architecture once for the binary installs below.
#      TARGETARCH is BuildKit's automatic per-platform ARG (correct even
#      when cross-building via buildx, unlike `dpkg --print-architecture`,
#      which only reflects the build host's own arch). Each tool names its
#      release assets differently, so the mapping still needs a per-tool
#      value, but resolving it once keeps that mapping in a single place
#      instead of repeating it in every install step below. asdf already
#      names its assets amd64/arm64, matching TARGETARCH directly, so it
#      reads TARGETARCH itself rather than a mapped entry here. -----------
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) printf 'HUNK_ARCH=%s\nCOPILOT_ARCH=%s\nMADO_ARCH=%s\n' x64 x64 x86_64 ;; \
        arm64) printf 'HUNK_ARCH=%s\nCOPILOT_ARCH=%s\nMADO_ARCH=%s\n' arm64 arm64 arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac > /etc/copilot-container-arch.env

# ---- Hunk CLI client (talks to the host's Hunk loopback daemon only; the
#      Hunk TUI itself always runs on the host) - no apt package upstream,
#      so verify the release tarball against its published SHA256SUMS. ----
RUN set -eux; \
    . /etc/copilot-container-arch.env; \
    workdir="$(mktemp -d)"; \
    cd "${workdir}"; \
    curl -fsSL -O "https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/hunkdiff-linux-${HUNK_ARCH}.tar.gz"; \
    curl -fsSL -O "https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/SHA256SUMS"; \
    grep " hunkdiff-linux-${HUNK_ARCH}.tar.gz\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "hunkdiff-linux-${HUNK_ARCH}.tar.gz" --strip-components=1; \
    install -m 0755 hunk /usr/local/bin/hunk; \
    cd /; rm -rf "${workdir}"

# ---- Copilot CLI (pinned) - no apt package upstream, so verify the
#      release tarball against its published SHA256SUMS.txt. -------------
RUN set -eux; \
    . /etc/copilot-container-arch.env; \
    workdir="$(mktemp -d)"; \
    cd "${workdir}"; \
    curl -fsSL -O "https://github.com/github/copilot-cli/releases/download/v${COPILOT_CLI_VERSION}/copilot-linux-${COPILOT_ARCH}.tar.gz"; \
    curl -fsSL -O "https://github.com/github/copilot-cli/releases/download/v${COPILOT_CLI_VERSION}/SHA256SUMS.txt"; \
    grep " copilot-linux-${COPILOT_ARCH}.tar.gz\$" SHA256SUMS.txt | sha256sum -c -; \
    tar -xzf "copilot-linux-${COPILOT_ARCH}.tar.gz"; \
    install -m 0755 copilot /usr/local/bin/copilot; \
    cd /; rm -rf "${workdir}"

# ---- mado (markdownlint-compatible Rust linter) - no apt package
#      upstream, so verify the release tarball against its published
#      .sha256 sidecar. -------------------------------------------------
RUN set -eux; \
    . /etc/copilot-container-arch.env; \
    workdir="$(mktemp -d)"; \
    cd "${workdir}"; \
    curl -fsSL -O "https://github.com/akiomik/mado/releases/download/v${MADO_VERSION}/mado-Linux-gnu-${MADO_ARCH}.tar.gz"; \
    curl -fsSL -O "https://github.com/akiomik/mado/releases/download/v${MADO_VERSION}/mado-Linux-gnu-${MADO_ARCH}.tar.gz.sha256"; \
    sha256sum -c "mado-Linux-gnu-${MADO_ARCH}.tar.gz.sha256"; \
    tar -xzf "mado-Linux-gnu-${MADO_ARCH}.tar.gz"; \
    install -m 0755 mado /usr/local/bin/mado; \
    cd /; rm -rf "${workdir}"

# ---- asdf (per-project language/tool version manager) - no apt package
#      upstream, and asdf only publishes MD5 checksums (no SHA256SUMS
#      file), so verify against that instead. Provisions everything
#      project-specific (Node, Go, Java, Python, Terraform/OpenTofu, ...)
#      on demand into the per-project persistent volume at ~/.asdf, rather
#      than baking one global version of each into the image (see the
#      first-run setup script for how this gets triggered). --------------
RUN set -eux; \
    workdir="$(mktemp -d)"; \
    cd "${workdir}"; \
    curl -fsSL -O "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VERSION}/asdf-v${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL -o asdf.tar.gz.md5 "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VERSION}/asdf-v${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz.md5"; \
    echo "$(cat asdf.tar.gz.md5)  asdf-v${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz" | md5sum -c -; \
    tar -xzf "asdf-v${ASDF_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    install -m 0755 asdf /usr/local/bin/asdf; \
    cd /; rm -rf "${workdir}"

RUN rm -f /etc/copilot-container-arch.env

# ---- Entrypoint ------------------------------------------------------------
COPY lib/entrypoint.sh /usr/local/bin/copilot-container-entrypoint
RUN chmod +x /usr/local/bin/copilot-container-entrypoint

# sshd config for the host<->container SSH link (see lib/sshd-config).
# Replaces Ubuntu's default sshd_config outright: this image never runs a
# general-purpose SSH server, only this narrowly-scoped one.
COPY lib/sshd-config /etc/ssh/sshd_config
RUN chmod 0644 /etc/ssh/sshd_config

# A non-root home dir template; entrypoint creates/aligns the actual runtime
# user's home at container start based on HOST_UID/HOST_GID.
RUN mkdir -p /home/copilot && chmod 0755 /home/copilot

ENTRYPOINT ["/usr/local/bin/copilot-container-entrypoint"]
