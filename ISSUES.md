# Known Issues / Open Items

Things that are intentionally not (yet) done, tracked in one place instead
of scattered across other docs.

## Untested

- **Docker.** Everything has only been built/run with Podman on macOS/arm64
  so far. Docker (and Linux in general) should work given the engine
  detection and host-gateway flags, but hasn't actually been exercised.
- **Hunk host-loopback reachability.** The `--add-host`/`HUNK_HOST` flags
  are wired up, but never verified end-to-end against a real, running Hunk
  daemon session on the host.

## Not designed yet

- **Commit signing (GPG/SSH).** `~/.gitconfig` is read-only bind-mounted,
  so identity/aliases/etc. work, but signing key material isn't handled.
  Open questions:
  - GPG signing: mount the host's GPG agent socket vs. importing a key into
    the container.
  - SSH signing (`gpg.format=ssh`): mount the host's `SSH_AUTH_SOCK` so
    signing happens via the host's agent, key material never entering the
    container.
  - Per-project (state volume) vs. global (mounted read-only every run)?
  - Cross-platform differences: agent socket forwarding works differently
    on macOS (Docker Desktop/Podman machine run in a VM, host socket needs
    proxying) vs. native Linux (direct socket bind-mount works).

## Not planned

- **No automated tests.** Verification has been manual smoke-testing only
  (build the image, run the launcher, check tool versions/mounts/seeding
  behavior by hand).
- **Windows is not a supported host platform.**
