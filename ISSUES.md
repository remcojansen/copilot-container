# Known Issues / Open Items

Things that are intentionally not (yet) done, tracked in one place instead
of scattered across other docs.

## Untested

- **Docker.** Everything has only been built/run with Podman on macOS/arm64
  so far. Docker (and Linux in general) should work given the engine
  detection and host-gateway flags, but hasn't actually been exercised.
- **The SSH-mediated launch flow.** The container always starts detached
  and the launcher always connects in over SSH to run `copilot`. This has
  passed the shell test suite but not yet been exercised end-to-end
  against a rebuilt image.
- **Hunk host-loopback reachability.** The `--add-host`/`HUNK_HOST` flags
  are wired up, but never verified end-to-end against a real, running Hunk
  daemon session on the host. Still uses host-gateway networking (not the
  SSH session the launcher establishes), since Hunk's daemon port isn't
  fixed/known ahead of time.

## Known trade-offs (SSH-mediated launch)

The container is always started detached and the launcher always connects
in over a narrowly-scoped SSH session to run `copilot` as the aligned
runtime user, forwarding the GPG/SSH agent sockets over that same session
when signing is requested. This avoids relying on virtiofs's bind-mount
socket semantics, but has some inherent costs:

- **Every invocation depends on sshd coming up successfully** inside the
  container; there's no other path in. A ping-then-real-session readiness
  check (with the last SSH error surfaced on timeout, see below) keeps
  failures diagnosable, but sshd being healthy is a hard requirement for
  every run, signing or not.
- **Each invocation pays for a container start, port-publish poll, sshd
  startup, and an SSH handshake** before `copilot` starts. Expected to be
  well under a second in practice, but it's there on every run.
- **An sshd listens (loopback-only, on an ephemeral published port) for
  every run.** Mitigated by a fresh single-use ed25519 keypair/host key per
  run, key-only auth, and `AllowTcpForwarding no` (only the two specific
  unix-socket forwards are ever permitted).
- **`ssh ... destination -- command`** (used to pass the remote command as
  a single already-quoted argv element) relies on OpenSSH's `--`
  end-of-options handling, added in OpenSSH 7.8 (2018). Any modern host
  `ssh` client should have this, but it hasn't been verified against every
  OpenSSH version macOS has shipped.

## Not planned

- **Windows is not a supported host platform.**
