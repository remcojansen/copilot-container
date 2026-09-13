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

- **SSH Commit Signing.** GPG commit signing is implemented via `--gpg-sign`
  (forwards host `gpg-agent` socket and read-only public keyrings). SSH signing
  (`gpg.format=ssh` / `--ssh-sign`) forwarding host `SSH_AUTH_SOCK` is planned.

## Not planned

- **Windows is not a supported host platform.**
