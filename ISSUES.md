# Known Issues / Open Items

Things that are intentionally not (yet) done, tracked in one place instead
of scattered across other docs.

## Untested

- **Docker.** Everything has only been built/run with Podman on macOS/arm64
  so far. Docker should work, but has not been tested.
- **Hunk host-loopback reachability.** The `--add-host`/`HUNK_HOST` flags
  are wired up, but never verified end-to-end against a real, running Hunk
  daemon session on the host.
- **Linux.** So far the tool has only been tested on macOS.

## Not planned

- **Windows is not a supported host platform.**
