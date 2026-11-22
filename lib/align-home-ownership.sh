#!/usr/bin/env bash

set -euo pipefail

runtime_home="${1:?missing runtime home}"
host_uid="${2:?missing host UID}"
host_gid="${3:?missing host GID}"
mountinfo="${4:-/proc/self/mountinfo}"

# NUL-terminated output preserves newlines in mount paths.
decode_mount_target() {
    printf '%b\0' "$1"
}

escape_find_pattern() {
    local path="$1"
    path="${path//\\/\\\\}"
    path="${path//\*/\\*}"
    path="${path//\?/\\?}"
    path="${path//\[/\\[}"
    printf '%s\0' "${path}"
}

# -xdev alone can still visit bind mounts, including their mountpoints.
prune_mounts=()
# The fifth mountinfo field is the mount target, with whitespace escaped.
while read -r _ _ _ _ encoded_target _; do
    IFS= read -r -d '' target < <(decode_mount_target "${encoded_target}")
    case "${target}" in
        "${runtime_home}/"*)
            IFS= read -r -d '' pattern < <(escape_find_pattern "${target}")
            prune_mounts+=(-path "${pattern}" -prune -o)
            ;;
    esac
done < "${mountinfo}"

find "${runtime_home}" -xdev "${prune_mounts[@]}" \
    ! -path "${runtime_home}/.gitconfig" \
    ! -path "${runtime_home}/.copilot-config-seed.json" \
    ! -path "${runtime_home}/.copilot/copilot-instructions.md" \
    ! -path "${runtime_home}/.gnupg*" \
    ! -path "${runtime_home}/.gnupg/*" \
    ! -path "${runtime_home}/.ssh" \
    ! -path "${runtime_home}/.ssh/*" \
    ! -path "${runtime_home}/.copilot-container-bridge" \
    ! -path "${runtime_home}/.copilot-container-bridge/*" \
    ! -path "${runtime_home}/.hunk" \
    ! -path "${runtime_home}/.hunk/*" \
    -exec chown "${host_uid}:${host_gid}" {} +
