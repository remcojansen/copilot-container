# copilot-container

Run [GitHub Copilot CLI](https://github.com/github/copilot-cli) inside a
container, smoothly. This project provides a container image with Copilot
CLI and a common dev toolchain, a launcher script that mounts your project(s)
and forwards your preferred Copilot CLI flags, container-tuned
Copilot defaults, personal user-level Copilot instructions, and integration
with [Hunk](https://hunk.dev/) (a host-side terminal diff reviewer).

## Prerequisites

- [Podman](https://podman.io/) (preferred) or [Docker](https://www.docker.com/)
- A GitHub token available as `GH_TOKEN` or `GITHUB_TOKEN` in your shell
  environment, or `gh` installed and authenticated (`gh auth login`) —
  used for `gh`/Copilot auth; passed into the container each run, never
  persisted to disk or baked into the image
- (Optional) [Hunk](https://hunk.dev/) installed on the host if you want
  agent-driven diff review
- OpenSSH client for the launcher to shell into the container image.

## Quickstart

```sh
# Build the image and install the launcher (from the repo root)
make build                                   # or: make build ENGINE=docker
make install                                 # copies bin/copilot-container to /usr/local/bin

# Run it against the current directory
cd /path/to/your/project
copilot-container -- --model claude-sonnet-5
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
2. Bind-mounts each `--mount`/`-m` path into the container at the same
   absolute path as on the host (unless you give an explicit
   `host:container` mapping). The *first* `--mount` is the primary project:
   the container's working directory, and the source for the per-project
   state volume name.
3. Creates/reuses a per-project named volume (derived from the first mount
   path), mounted at the container user's home directory, so Copilot CLI 
   config, permission approvals, and session/history state persist per project.
4. If `~/.gitconfig` exists on the host, bind-mounts it read-only into the
   container (see [Git configuration](#git-configuration) below).
5. If `~/.copilot/config.json` exists on the host, seeds the config into the
   container on the first run for a given project.
6. If `~/.copilot/copilot-instructions.md` exists on the host, bind-mounts it
   read-only into the container (see [Copilot config and instructions](#copilot-config-and-instructions)
   below).
7. Passes `GH_TOKEN`/`GITHUB_TOKEN` from your host shell into the remote
   `copilot` invocation for that run only (nothing is written to the image
   or the persistent volume). Falls back to `gh auth token` if `GH_TOKEN`
   is unset but `gh` is authenticated.
8. With `--hunk-agent`, mounts Hunk's host runtime state read-only and
   forwards its loopback-only broker over SSH so tools inside the container
   can control host-side Hunk sessions.
9. Starts the container **detached**, then connects in over a narrowly-scoped,
   loopback-only SSH session (fresh single-use keypair, torn down with the
   container) to run `copilot` as the aligned runtime user, forwarding any
   args you passed after `--`. See [Architecture](#architecture) below for
   why.

### Options

```
copilot-container [-m <path> ...] [options] [-- <copilot CLI args...>]

  -m, --mount <host_path>[:<container_path>]
                                 Bind-mount a host directory (repeatable).
                                 If no --mount/-m is given at all, defaults
                                 to the current working directory (`pwd`).
                                 Defaults to the same path in the container
                                 as on the host. The first --mount is the
                                 primary project.
  -i, --image <name>            Container image to run (default: copilot-container)
  -e, --engine <podman|docker>  Force a specific container engine
  -g, --gitconfig <path>        Host file to mount read-only as ~/.gitconfig
                                 (default: ~/.gitconfig)
  --gpg-agent                   Forward host gpg-agent socket and mount public keyrings
                                 read-only for GPG commit signing
  --ssh-agent                   Forward host SSH_AUTH_SOCK (ssh-agent) for SSH public-key
                                 auth and SSH commit signing
  --hunk-agent                  Enable agent access to host Hunk live sessions
  -h, --help                    Show help
```

Example with multiple mounted projects, custom gitconfig, GPG agent forwarding and additional copilot flags:

```sh
copilot-container \
  -m /path/to/your/first-project \
  -m /path/to/your/second-project \
  --gpg-agent \
  --gitconfig ~/.gitconfig-default \
  -- \
  --model claude-sonnet-5 \
  --allow-all-tools \
  --allow-all-paths
```

`/path/to/your/first-project` is the primary project (container's working directory, and
the one used to name the persistent state volume).

Environment variables:

| Variable | Purpose |
|---|---|
| `GH_TOKEN` / `GITHUB_TOKEN` | Forwarded into the container for the run (falls back to `gh auth token` if unset) |
| `HUNK_MCP_PORT` | Forwarded into the container with `--hunk-agent` if set |
| `COPILOT_CONTAINER_ENGINE` | Force `podman` or `docker` |
| `COPILOT_CONTAINER_IMAGE`  | Default image name/tag to run |

## Engine selection

Podman is preferred; Docker is used automatically if Podman isn't on your
`PATH`. Override explicitly with `-e/--engine` or `COPILOT_CONTAINER_ENGINE`.

## Copilot config and instructions

Copilot CLI stores its config, remembered permission approvals, and
session/chat history together under `$HOME/.copilot`. That whole directory
is the per-project persistent volume (see above), so most of it evolves
freely per project.

Two files are the exception: if `$HOME/.copilot/config.json` and/or
`$HOME/.copilot/copilot-instructions.md` already exist on the **host**,
the container picks up your existing settings instead of starting blank.
If a file doesn't exist on the host, it's just absent inside the container
too (no fallback).

`copilot-instructions.md` is bind-mounted read-only at the same relative
path — it's not written to by the CLI, so edit it on the host if you want
to change it.

`config.json` is different: the CLI writes to it at runtime (e.g. to
remember per-directory trust approvals), so it can't simply be bind-mounted
read-only without breaking that. Instead, the host's `config.json` is
mounted read-only to a staging path, and the entrypoint seed-copies it into
the writable per-project volume the *first* time a project is run. From
then on, that project's volume owns its `config.json`: approvals and other
config changes made from inside the container persist across sessions,
and later edits to the host file aren't re-synced (matching how the rest
of `~/.copilot` behaves).

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

### Agent forwarding (GPG / SSH)

`--gpg-agent` and `--ssh-agent` forward your host's `gpg-agent` socket
and/or `SSH_AUTH_SOCK` (ssh-agent) into the container, over the same SSH
session the launcher always establishes (see [Architecture](#architecture)
above). Your private key material remains strictly on the host — only the
live agent socket is forwarded, plus your GPG public keyrings
(`pubring.kbx` / `pubring.gpg`) read-only.

```sh
copilot-container -m ~/code/my-project --gpg-agent
copilot-container -m ~/code/my-project --ssh-agent
```

Ensure `gpg-agent`/`ssh-agent` is active on your host before running. Because
`~/.gitconfig` is mounted read-only, Git inside the container inherits your
`user.signingKey`/`gpg.format` and `commit.gpgSign` configuration
automatically.

When `--ssh-agent` is used and `~/.ssh/known_hosts` exists on the host, it is
mounted read-only as `/etc/ssh/ssh_known_hosts` so GitHub SSH remotes can use
the forwarded agent without a separate host-key prompt inside the container.

## Hunk integration

[Hunk](https://hunk.dev/) is a terminal diff reviewer. Its TUI **is expected to run
on the host** — it registers with a local loopback daemon that the `hunk`
CLI talks to. The container only needs the `hunk` CLI **client** (already
installed in the image) plus network reachability to that host daemon,
which the launcher sets up when `--hunk-agent` is enabled.
This integration is opt-in: run the launcher with `--hunk-agent` when you want
Copilot to inspect, navigate, or comment on a live host-side Hunk session.

To use it:

1. On the host, open a review: `hunk diff` (or `hunk show`, etc.) from the
   same repo root you're mounting into the container via `--mount`.
2. Start Copilot with `--hunk-agent`:
   `copilot-container -m /path/to/repo --hunk-agent`.
3. Inside the container, verify the agent can see the live session, using
   the same path you mounted: `hunk session list --repo <path>`.
4. Ask Copilot to load the Hunk review skill (`hunk skill path`) and use
   `hunk session ...` commands to navigate/comment as described in
   [Hunk's agent workflow docs](https://github.com/modem-dev/hunk/blob/main/docs/agent-workflows.md).

Because `--mount` preserves the host's absolute path inside the container,
matching by repo root is predictable as long as you run Hunk on the host
against the exact directory you passed to `--mount`.

`--hunk-agent` forwards Hunk's host broker port to the same loopback port
inside the container over the launcher's SSH connection. The Hunk CLI
therefore connects to `127.0.0.1` and retains the broker's loopback-only
security checks. `HUNK_MCP_PORT` selects a non-default broker port when set.
The launcher also mounts the host broker runtime state read-only from
`$XDG_RUNTIME_DIR/hunk-mcp` when available, or `$HOME/.hunk/hunk-mcp`
otherwise. If neither exists, start a Hunk window on the host first.

## Container image contents

Built from `ubuntu:24.04`, the image includes:

- GitHub Copilot CLI (pinned version, see below)
- `git`, `gh` (GitHub CLI), `glab` (GitLab CLI)
- `go`, a JDK (OpenJDK 21), `python3`
- `tofu` (OpenTofu, Terraform-compatible CLI), with `terraform` symlinked to
  `tofu`
- Common Unix utilities: `make`, `sed`, `gawk`, `grep`, `ripgrep` (`rg`),
  `vim`, `tar`
- `markdownlint-cli`
- `hunk` (CLI client only — see [Hunk integration](#hunk-integration))
- `openssh-server`, used to accept the launcher's per-run SSH session (see
  [Architecture](#architecture) above) — the entrypoint aligns the runtime
  user's UID/GID and seeds Copilot config, then hands off to sshd as the
  container's foreground process; `copilot` itself runs inside that SSH
  session, not the entrypoint

This list is expected to grow — add packages to `Containerfile` as needed.

### Package installation approach

Packages available in Ubuntu's apt repositories (`git`, `make`, `sed`,
`gawk`, `grep`, `ripgrep`, `golang-go`, `openjdk-21-jdk-headless`,
`python3`, `vim`, `tar`, `openssh-server`, `glab`, ...) are installed via
`apt-get`, since they're GPG-signed, mirrored, and get security updates
automatically. `gh` and Node.js (newer than Ubuntu's packaged version) are
installed from their own signed apt repositories (maintainer's GPG key +
sources file), rather than piping an install script to `bash`. OpenTofu is
installed from its signed apt repository. Copilot CLI is installed via `npm`
(pinned version, verified by npm's registry integrity hash); Hunk's release
tarball is checksum-verified against its published `SHA256SUMS`.

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

## Licensing

This repository's own code is MIT-licensed (see `LICENSE`). The container
image also bundles unmodified third-party software — most notably GitHub
Copilot CLI, redistributed under its own license — alongside the
functionality this project adds (the launcher, host/container SSH bridge,
Git/Copilot config wiring, Hunk integration, and the rest of the toolchain).
See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for the full license
text and attribution notices for bundled third-party components.

This project is not affiliated with, endorsed by, or sponsored by GitHub,
Inc. "GitHub" and "GitHub Copilot" are trademarks of GitHub, Inc.

## Known limitations / not yet implemented

- **Keyring/keychain forwarding** is missing. Copilot authentication requires
  an authenticated github-cli session on the host or storing the token in plain
  text on the attached volume inside the container.
- **Docker support has NOT been tested.** Everything has been built/run with
  Podman on macOS/arm64 and Linux so far. 
- **Windows is not a supported host platform.**
