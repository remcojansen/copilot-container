#!/usr/bin/env bash
#
# copilot-container entrypoint
#
# Responsibilities:
#   - Create/align a runtime user matching the host UID/GID (HOST_UID/
#     HOST_GID) so files written into bind-mounted volumes aren't
#     root-owned on the host.
#   - Install the launcher-supplied SSH key for that user and start sshd
#     as the container's foreground process. The host launcher always
#     connects in over SSH to run the actual Copilot CLI command.
set -euo pipefail

RUNTIME_USER="copilot"
RUNTIME_HOME="/home/${RUNTIME_USER}"

HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

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
    existing_uid_user="$(getent passwd "${HOST_UID}" | cut -d: -f1 | head -n1 || true)"
    if [ -n "${existing_uid_user}" ]; then
        # The base image may already assign HOST_UID (usually 1000). Reuse
        # that account instead of asking useradd to create a duplicate UID.
        usermod -l "${RUNTIME_USER}" -d "${RUNTIME_HOME}" -g "${runtime_group}" \
            -s /bin/bash "${existing_uid_user}"
    else
        useradd -d "${RUNTIME_HOME}" -u "${HOST_UID}" -g "${runtime_group}" \
            -K UID_MIN=100 -K UID_MAX=60000 -s /bin/bash "${RUNTIME_USER}"
    fi
else
    if ! usermod -u "${HOST_UID}" -g "${runtime_group}" "${RUNTIME_USER}" >/dev/null 2>&1; then
        echo "error: unable to align ${RUNTIME_USER} with UID ${HOST_UID} and GID ${HOST_GID}" >&2
        exit 1
    fi
fi

# useradd/usermod leave the password field locked ("!"), which sshd rejects
# outright for any authentication method.
# Only pubkey login is ever possible here (no password is ever set), 
# so just clear the lock; this doesn't grant password login on its own.
usermod -p '*' "${RUNTIME_USER}"

# --- Seed the writable Copilot config from the read-only host mount -----
# config.json is bind-mounted read-only at .copilot-config-seed.json
# rather than directly at its final path. Seed a writable copy into place on
# first run; later runs reuse what is already in the volume.
CONFIG_SEED="${RUNTIME_HOME}/.copilot-config-seed.json"
if [ -f "${CONFIG_SEED}" ] && [ ! -f "${RUNTIME_HOME}/.copilot/config.json" ]; then
    mkdir -p "${RUNTIME_HOME}/.copilot"
    cp "${CONFIG_SEED}" "${RUNTIME_HOME}/.copilot/config.json"
fi

# Read-only config files and mounted sockets under the home directory
# cannot be chowned. Exclude those paths while aligning the writable state
# volume. .ssh and .copilot-container-bridge are excluded too: they're
# (re)created fresh with correct ownership further below, every run.
find "${RUNTIME_HOME}" -xdev \
    ! -path "${RUNTIME_HOME}/.gitconfig" \
    ! -path "${CONFIG_SEED}" \
    ! -path "${RUNTIME_HOME}/.copilot/copilot-instructions.md" \
    ! -path "${RUNTIME_HOME}/.gnupg*" \
    ! -path "${RUNTIME_HOME}/.gnupg/*" \
    ! -path "${RUNTIME_HOME}/.ssh" \
    ! -path "${RUNTIME_HOME}/.ssh/*" \
    ! -path "${RUNTIME_HOME}/.copilot-container-bridge" \
    ! -path "${RUNTIME_HOME}/.copilot-container-bridge/*" \
    -exec chown "${HOST_UID}:${HOST_GID}" {} +

# --- SSH login for the host launcher -------------------------------------
# The host launcher always starts this container detached and connects in
# over SSH as this same runtime user to run the actual Copilot CLI command.
if [ -z "${AUTHORIZED_KEYS_B64:-}" ]; then
    echo "error: AUTHORIZED_KEYS_B64 is not set (expected to be supplied by the launcher)" >&2
    exit 1
fi
mkdir -p "${RUNTIME_HOME}/.ssh"
base64 -d <<< "${AUTHORIZED_KEYS_B64}" > "${RUNTIME_HOME}/.ssh/authorized_keys"
chmod 0700 "${RUNTIME_HOME}/.ssh"
chmod 0600 "${RUNTIME_HOME}/.ssh/authorized_keys"
chown -R "${HOST_UID}:${HOST_GID}" "${RUNTIME_HOME}/.ssh"
unset AUTHORIZED_KEYS_B64

# Shared directory for forwarded gpg-agent/ssh-agent sockets
mkdir -p "${RUNTIME_HOME}/.copilot-container-bridge"
chown "${HOST_UID}:${HOST_GID}" "${RUNTIME_HOME}/.copilot-container-bridge"
chmod 0700 "${RUNTIME_HOME}/.copilot-container-bridge"

# Without this, gpg silently auto-starts its own local agent (with no
# keys) if GNUPGHOME ever points here but nothing has forwarded a socket
# in yet, masking a dead tunnel as a confusing "no secret key" error
# instead of a clear "no agent" one.
echo "no-autostart" > "${RUNTIME_HOME}/.copilot-container-bridge/gpg.conf"
chown "${HOST_UID}:${HOST_GID}" "${RUNTIME_HOME}/.copilot-container-bridge/gpg.conf"
chmod 0600 "${RUNTIME_HOME}/.copilot-container-bridge/gpg.conf"

ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/copilot_container_host_key <<< y >/dev/null
mkdir -p /run/sshd
chmod 0755 /run/sshd
exec /usr/sbin/sshd -D -e
