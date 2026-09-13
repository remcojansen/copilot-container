#!/usr/bin/env bash
#
# copilot-container entrypoint
#
# Responsibilities:
#   - Create/align a runtime user matching the host UID/GID (HOST_UID/
#     HOST_GID) so files written into bind-mounted volumes aren't
#     root-owned on the host.
#   - cd into the primary mounted project (PRIMARY_WORKSPACE) and exec into
#     the requested command (default: `copilot`) as the runtime user,
#     passing through all arguments.
set -euo pipefail

RUNTIME_USER="copilot"
RUNTIME_HOME="/home/${RUNTIME_USER}"

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
PRIMARY_WORKSPACE="${PRIMARY_WORKSPACE:-${RUNTIME_HOME}}"

case "${HOST_UID}" in
    ''|*[!0-9]*) echo "error: HOST_UID must be a numeric user ID" >&2; exit 1 ;;
esac
case "${HOST_GID}" in
    ''|*[!0-9]*) echo "error: HOST_GID must be a numeric group ID" >&2; exit 1 ;;
esac

# --- Align runtime user with host UID/GID --------------------------------
# UID_MIN/UID_MAX are overridden because bind-mounted host UIDs (e.g. macOS's
# default 501/502) commonly fall outside useradd's default system-user
# range; this is expected here, not a misconfiguration.
# The home directory is created ourselves (below) rather than via useradd's
# -m, since it may already be populated by the per-project volume — this
# also avoids useradd's "already exists"/skel-copy warnings.
mkdir -p "${RUNTIME_HOME}"

if ! getent group "${HOST_GID}" >/dev/null 2>&1; then
    groupadd -g "${HOST_GID}" "${RUNTIME_USER}"
fi
runtime_group="$(getent group "${HOST_GID}" | cut -d: -f1)"

if ! id -u "${RUNTIME_USER}" >/dev/null 2>&1; then
    useradd -d "${RUNTIME_HOME}" -u "${HOST_UID}" -g "${runtime_group}" \
        -K UID_MIN=100 -K UID_MAX=60000 -s /bin/bash "${RUNTIME_USER}"
else
    if ! usermod -u "${HOST_UID}" -g "${runtime_group}" "${RUNTIME_USER}" >/dev/null 2>&1; then
        echo "error: unable to align ${RUNTIME_USER} with UID ${HOST_UID} and GID ${HOST_GID}" >&2
        exit 1
    fi
fi

# Read-only config files and mounted sockets under the home directory cannot be
# chowned. Exclude those paths while aligning the writable state volume.
find "${RUNTIME_HOME}" -xdev \
    ! -path "${RUNTIME_HOME}/.gitconfig" \
    ! -path "${RUNTIME_HOME}/.copilot/config.json" \
    ! -path "${RUNTIME_HOME}/.copilot/copilot-instructions.md" \
    ! -path "${RUNTIME_HOME}/.gnupg*" \
    ! -path "${RUNTIME_HOME}/.gnupg/*" \
    -exec chown "${HOST_UID}:${HOST_GID}" {} +

# --- cd into the primary project and exec as the runtime user -----------
cd "${PRIMARY_WORKSPACE}"
exec gosu "${RUNTIME_USER}" "$@"
