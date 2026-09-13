# copilot-container

Run [GitHub Copilot CLI](https://github.com/github/copilot-cli) inside a
container, smoothly. This project provides a prebuilt container image with
Copilot CLI and a common dev toolchain, a launcher script that mounts your
project(s) and forwards your preferred Copilot CLI flags, container-tuned
Copilot defaults, personal user-level Copilot instructions, and integration
with [Hunk](https://hunk.dev/) (a host-side terminal diff reviewer).

## Prerequisites

- [Podman](https://podman.io/) (preferred) or [Docker](https://www.docker.com/)
- A GitHub token available as `GH_TOKEN` or `GITHUB_TOKEN` in your shell
  environment (used for `gh`/Copilot auth; passed into the container each
  run, never persisted to disk or baked into the image)
- (Optional) [Hunk](https://hunk.dev/) installed on the host if you want
  agent-driven diff review

## Quickstart

```sh
# Build the image and install the launcher (from the repo root)
make build                                   # or: make build ENGINE=docker
make install                                 # copies bin/copilot-container to /usr/local/bin

# Run it against the current directory
cd /path/to/your/project
copilot-container -m "$(pwd)" -- --model claude-sonnet-4.5
```

Everything after `--` is forwarded verbatim to the `copilot` CLI inside the
container (model selection, permission/approval flags, etc.) — no
project-specific presets, just pass what you want each time.

`make install` copies the script (not a symlink) to `$(PREFIX)/bin`
(default `/usr/local/bin`; override with e.g. `make install
PREFIX=$HOME/.local`). `make uninstall` removes it. See `make help` for all
targets. Without `make`, you can also just add the `bin/` directory to your
`PATH` directly, or build/run the image manually with `podman build`/`docker
build`.

## What the launcher does

`bin/copilot-container`:

1. Detects your container engine — **Podman first, Docker as fallback** (see
   [Engine selection](#engine-selection) below).
2. Bind-mounts each `--mount`/`-m` path into the container at the **same
   absolute path** as on the host (unless you give it an explicit
   `host:container` mapping), so paths stay recognizable between host and
   container. The *first* `--mount` is the primary project: the container's
   working directory, and the source for the per-project state volume name.
3. Creates/reuses a **per-project named volume** (derived from the primary
   project's absolute path) mounted at the container user's home directory,
   so Copilot CLI config, permission approvals, and session/history state
   persist across runs of the same project without mixing state between
   different projects.
4. If `~/.gitconfig` exists on the host, bind-mounts it read-only into the
   container (see [Git configuration](#git-configuration) below).
5. If `~/.copilot/config.json` and/or `~/.copilot/copilot-instructions.md`
   exist on the host, bind-mounts them read-only into the container (see
   [Copilot config and instructions](#copilot-config-and-instructions)
   below).
6. Passes `GH_TOKEN`/`GITHUB_TOKEN` from your host shell into the container
   environment for that run only (nothing is written to the image or to the
   persistent volume).
7. Adds the host-loopback route (`--add-host`) so tools inside the container
   can reach services bound to the host's loopback interface — this is what
   makes the [Hunk integration](#hunk-integration) work.
8. Execs into `copilot`, forwarding any args you passed after `--`.

### Options

```
copilot-container -m <path> [-m <path> ...] [options] [-- <copilot CLI args...>]

  -m, --mount <host_path>[:<container_path>]
                                 Bind-mount a host directory (repeatable,
                                 at least one required). Defaults to the
                                 same path in the container as on the host.
                                 The first --mount is the primary project.
  -i, --image <name>            Container image to run (default: copilot-container)
  -e, --engine <podman|docker>  Force a specific container engine
  -g, --gitconfig <path>        Host file to mount read-only as ~/.gitconfig
                                 (default: ~/.gitconfig)
  --gpg-sign                    Enable GPG commit signing (forwards host gpg-agent socket
                                 and mounts public keyrings read-only)
  -h, --help                    Show help
```

Example with multiple mounted projects (e.g. a main repo plus a reference repo):

```sh
copilot-container -m ~/code/my-app -m ~/code/shared-lib -- --model claude-sonnet-4.5
```

`~/code/my-app` is the primary project (container's working directory, and
the one used to name the persistent state volume); `~/code/shared-lib` is
mounted alongside it at the same path.

Environment variables:

| Variable | Purpose |
|---|---|
| `GH_TOKEN` / `GITHUB_TOKEN` | Forwarded into the container for the run |
| `COPILOT_CONTAINER_ENGINE` | Force `podman` or `docker` |
| `COPILOT_CONTAINER_IMAGE`  | Default image name/tag to run |

## Engine selection

Podman is preferred; Docker is used automatically if Podman isn't on your
`PATH`. Override explicitly with `-e/--engine` or `COPILOT_CONTAINER_ENGINE`.

Host-loopback reachability (needed for Hunk) is handled per engine:

- **Docker Desktop (macOS)**: `host.docker.internal` resolves natively.
- **Docker on Linux**: an explicit `--add-host=host.docker.internal:host-gateway` is added.
- **Podman (macOS & Linux)**: `host.containers.internal` plus a
  `host-gateway` fallback mapping for older Podman versions.

## Copilot config and instructions

Copilot CLI stores its config, remembered permission approvals, and
session/chat history together under `$HOME/.copilot`. That whole directory
is the per-project persistent volume (see above), so most of it evolves
freely per project.

Two files are the exception: if `$HOME/.copilot/config.json` and/or
`$HOME/.copilot/copilot-instructions.md` already exist on the **host**,
they're bind-mounted read-only into the container at the same relative
path. Nothing is baked into the image or copied — the container simply
sees whatever you already have configured on your host machine. If a file
doesn't exist on the host, it's just absent inside the container too (no
fallback).

Because they're read-only, changes made from inside the container (e.g.
running `copilot` and having it update its own config) won't persist —
edit these files on the host if you want to change them.

`copilot-instructions.md` is Copilot CLI's **user-level instructions file**
(applies across all repositories you use inside the container) — it is
never copied into a project's workspace, so it never conflicts with or
overrides a project's own `AGENTS.md` / `.github/copilot-instructions.md`.

## Git configuration

If `~/.gitconfig` exists on the host, the launcher bind-mounts it read-only
at `/home/copilot/.gitconfig` inside the container. This gives `git` inside
the container your identity, aliases, and other global settings without
copying anything into the image or the persistent state volume.

Use `-g/--gitconfig <path>` to mount a different host file instead — handy
if you keep separate profiles (e.g. `~/.gitconfig-work`) and want to pick
one per project:

```sh
copilot-container -m ~/code/work-project -g ~/.gitconfig-work
```

It's mounted **read-only**: changes made from inside the container (e.g.
`git config --global ...`) do not persist back to the host file. Run those
commands on the host instead.

### GPG Commit Signing

Pass `--gpg-sign` to forward your host's running `gpg-agent` socket into the
container and mount your public keyrings (`pubring.kbx` / `pubring.gpg`)
read-only. Your private key material remains strictly on the host.

```sh
copilot-container -m ~/code/my-project --gpg-sign
```

Ensure `gpg-agent` is active on your host before running. Because `~/.gitconfig`
is mounted read-only, Git inside the container inherits your `user.signingKey`
and `commit.gpgSign` configuration automatically.

## Hunk integration

[Hunk](https://hunk.dev/) is a terminal diff reviewer. Its TUI **always runs
on the host** — it registers with a local loopback daemon that the `hunk`
CLI talks to. The container only needs the `hunk` CLI **client** (already
installed in the image) plus network reachability to that host daemon,
which the launcher sets up automatically.

To use it:

1. On the host, open a review: `hunk diff` (or `hunk show`, etc.) from the
   same repo root you're mounting into the container via `--mount`.
2. Inside the container, verify the agent can see the live session, using
   the same path you mounted: `hunk session list --repo <path>`.
3. Ask Copilot to load the Hunk review skill (`hunk skill path`) and use
   `hunk session ...` commands to navigate/comment as described in
   [Hunk's agent workflow docs](https://github.com/modem-dev/hunk/blob/main/docs/agent-workflows.md).

Because `--mount` preserves the host's absolute path inside the container,
matching by repo root is predictable as long as you run Hunk on the host
against the exact directory you passed to `--mount`.

## Container image contents

Built from `ubuntu:24.04`, the image includes:

- GitHub Copilot CLI (pinned version, see below)
- `git`, `gh` (GitHub CLI), `glab` (GitLab CLI)
- `go`, a JDK (OpenJDK 21), `python3`
- Common Unix utilities: `make`, `sed`, `gawk`, `grep`, `ripgrep` (`rg`),
  `vim`, `tar`
- `markdownlint-cli`
- `hunk` (CLI client only — see [Hunk integration](#hunk-integration))
- `gosu`, used by the entrypoint to run Copilot CLI as a non-root user whose
  UID/GID match your host user (so files written into mounted directories
  aren't root-owned)

This list is expected to grow — add packages to `Containerfile` as needed.

### Package installation approach

Packages available in Ubuntu's own apt repositories (`git`, `make`, `sed`,
`gawk`, `grep`, `ripgrep`, `golang-go`, `openjdk-21-jdk-headless`,
`python3`, `vim`, `tar`, `gosu`, `glab`, ...) are installed via `apt-get`
rather than downloaded directly, since they're GPG-signed by Ubuntu,
mirrored, and receive security updates automatically. `gh` and Node.js
(needed by Copilot CLI/markdownlint-cli, newer than Ubuntu's packaged
version) are installed from their own signed apt repositories by fetching
the maintainer's GPG key and writing the apt sources file directly, rather
than piping an install script to `bash`. Copilot CLI and Hunk have no apt
packages: Copilot CLI is installed via `npm` (pinned version, verified by
npm's registry integrity hash), and Hunk's release tarball is downloaded
and checksum-verified against its published `SHA256SUMS` before install.

## Updating the pinned Copilot CLI version

The Copilot CLI version is pinned via a build arg, defaulting to a known-good
version. To bump it:

```sh
podman build --build-arg COPILOT_CLI_VERSION=X.Y.Z -t copilot-container .
```

Once you've verified the new version works well, update the default in
`Containerfile` (`ARG COPILOT_CLI_VERSION=...`).

`HUNK_VERSION`, `NODE_MAJOR`, and `MARKDOWNLINT_CLI_VERSION` can be bumped
the same way via their respective `--build-arg` options. The Ubuntu base image
is pinned by digest and should be refreshed deliberately when updating the
base OS.

## Design notes

- **Mount paths match the host** so they stay recognizable and Hunk's
  `--repo <path>` matching stays predictable. The first `-m` is the primary
  project (working directory + state-volume name source).
- **`~/.copilot` is one writable per-project volume**, holding config,
  permission approvals, and session history together, since they evolve
  together. `config.json` and `copilot-instructions.md` are read-only
  bind-mounted from the host *inside* that volume, so the container
  reflects your real settings.
- **Packages install via Ubuntu's signed apt repos** where available. `gh`
  and Node.js use their own signed repos (GPG key + sources file added
  directly). Copilot CLI relies on npm's integrity hashes; Hunk's release
  tarball is checksum-verified against its `SHA256SUMS`.

## Known limitations / not yet implemented

See [`ISSUES.md`](ISSUES.md) for the current list of untested, undesigned,
and out-of-scope items.
