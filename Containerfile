# syntax=docker/dockerfile:1
#
# copilot-container image: Ubuntu-based dev environment with GitHub Copilot
# CLI, a common toolchain (go/java/python3/unix utils/git/gh/glab/
# OpenTofu/markdownlint) and the Hunk CLI client preinstalled.
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
ARG NODE_VERSION=22.20.0
ARG GO_VERSION=1.27.1
ARG MAVEN_VERSION=3.9.16
ARG JAVA_VERSION=21.0.12.1+1
ARG TOFU_VERSION=1.12.6

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
# Node.js, Go, Maven, OpenJDK (Temurin) and OpenTofu are installed from
# pinned, checksum-verified upstream release tarballs below instead of apt:
# it lets the ARGs above pin an exact version consistently with the other
# binary-installed tools (Copilot CLI, Hunk, mado), rather than relying on
# whatever version a third-party apt repo happens to serve.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git make sed gawk grep ripgrep \
        python3 python3-pip python3-venv \
        unzip xz-utils tar less nano vim \
        jq shellcheck \
        glab openssh-server \
        gh \
    && rm -rf /var/lib/apt/lists/*

# ---- Shared installer for pinned, checksum-verified release tarballs -----
COPY lib/install-release.sh /usr/local/sbin/install-release.sh
RUN chmod 0755 /usr/local/sbin/install-release.sh

# ---- Resolve the target architecture once for the binary installs below.
#      TARGETARCH is BuildKit's automatic per-platform ARG (correct even
#      when cross-building via buildx, unlike `dpkg --print-architecture`,
#      which only reflects the build host's own arch). Each tool names its
#      release assets differently, so the mapping still needs a per-tool
#      value, but resolving it once keeps that mapping in a single place
#      instead of repeating it in every install step below. Go and OpenTofu
#      already name their assets amd64/arm64, matching TARGETARCH directly,
#      so they read TARGETARCH itself rather than a mapped entry here. ----
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) printf 'HUNK_ARCH=%s\nCOPILOT_ARCH=%s\nMADO_ARCH=%s\nNODE_ARCH=%s\nTEMURIN_ARCH=%s\n' x64 x64 x86_64 x64 x64 ;; \
        arm64) printf 'HUNK_ARCH=%s\nCOPILOT_ARCH=%s\nMADO_ARCH=%s\nNODE_ARCH=%s\nTEMURIN_ARCH=%s\n' arm64 arm64 arm64 arm64 aarch64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac > /etc/copilot-container-arch.env

# ---- Hunk CLI client (talks to the host's Hunk loopback daemon only; the
#      Hunk TUI itself always runs on the host). ---------------------------
RUN . /etc/copilot-container-arch.env && install-release.sh \
        --name hunk --mode bin --strip-components 1 \
        --url "https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/hunkdiff-linux-${HUNK_ARCH}.tar.gz" \
        --checksum-url "https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/SHA256SUMS" \
        --checksum-style sumfile

# ---- Copilot CLI (pinned) -------------------------------------------------
RUN . /etc/copilot-container-arch.env && install-release.sh \
        --name copilot --mode bin \
        --url "https://github.com/github/copilot-cli/releases/download/v${COPILOT_CLI_VERSION}/copilot-linux-${COPILOT_ARCH}.tar.gz" \
        --checksum-url "https://github.com/github/copilot-cli/releases/download/v${COPILOT_CLI_VERSION}/SHA256SUMS.txt" \
        --checksum-style sumfile

# ---- mado (markdownlint-compatible Rust linter) --------------------------
RUN . /etc/copilot-container-arch.env && install-release.sh \
        --name mado --mode bin \
        --url "https://github.com/akiomik/mado/releases/download/v${MADO_VERSION}/mado-Linux-gnu-${MADO_ARCH}.tar.gz" \
        --checksum-url "https://github.com/akiomik/mado/releases/download/v${MADO_VERSION}/mado-Linux-gnu-${MADO_ARCH}.tar.gz.sha256" \
        --checksum-style sumfile

# ---- Node.js (merged directly into /usr/local, matching upstream Docker
#      image convention) --------------------------------------------------
RUN . /etc/copilot-container-arch.env && install-release.sh \
        --name node --mode merge --strip-components 1 --dest /usr/local \
        --url "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        --checksum-url "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
        --checksum-style sumfile

# ---- Go (installed as a self-contained tree at /usr/local/go; only the
#      go.dev/dl JSON API publishes a per-release checksum, so it's queried
#      directly with jq instead of a downloadable checksum file). ---------
RUN install-release.sh \
        --name go --mode tree --strip-components 1 --dest /usr/local/go \
        --url "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" \
        --checksum-url "https://go.dev/dl/?mode=json&include=all" \
        --checksum-style jsonapi \
        --jq-filter ".[] | select(.version==\"go${GO_VERSION}\") | .files[] | select(.filename==\"go${GO_VERSION}.linux-${TARGETARCH}.tar.gz\") | .sha256" \
        --link bin/go=go --link bin/gofmt=gofmt

# ---- Apache Maven (universal binary, no per-arch tarball) ----------------
RUN install-release.sh \
        --name maven --mode tree --strip-components 1 --dest /opt/apache-maven \
        --url "https://downloads.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        --checksum-url "https://downloads.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz.sha512" \
        --checksum-style rawhash --hash-algo sha512 \
        --link bin/mvn=mvn

# ---- Eclipse Temurin OpenJDK -----------------------------------------
RUN . /etc/copilot-container-arch.env && install-release.sh \
        --name jdk --mode tree --strip-components 1 --dest /opt/temurin-jdk \
        --url "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JAVA_VERSION}/OpenJDK21U-jdk_${TEMURIN_ARCH}_linux_hotspot_$(echo "${JAVA_VERSION}" | tr '+' '_').tar.gz" \
        --checksum-url "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JAVA_VERSION}/OpenJDK21U-jdk_${TEMURIN_ARCH}_linux_hotspot_$(echo "${JAVA_VERSION}" | tr '+' '_').tar.gz.sha256.txt" \
        --checksum-style sumfile \
        --link bin/java=java --link bin/javac=javac --link bin/jar=jar --link bin/javadoc=javadoc
ENV JAVA_HOME=/opt/temurin-jdk

# ---- OpenTofu (Terraform-compatible CLI) ---------------------------------
RUN install-release.sh \
        --name tofu --mode bin \
        --url "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.tar.gz" \
        --checksum-url "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS" \
        --checksum-style sumfile

RUN ln -s /usr/local/bin/tofu /usr/local/bin/terraform

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
