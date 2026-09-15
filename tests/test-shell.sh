#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LAUNCHER="${ROOT_DIR}/bin/copilot-container"
ENTRYPOINT="${ROOT_DIR}/lib/entrypoint.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    echo "ok - $1"
}

assert_output_contains() {
    local expected="$1"
    shift
    local output status=0
    output="$("$@" 2>&1)" || status=$?
    if [ "${status}" -eq 0 ]; then
        fail "expected command to fail: $*"
    fi
    printf '%s\n' "${output}" | grep -Fq -- "${expected}" ||
        fail "expected output to contain: ${expected}"
}

PROJECT="${TEST_DIR}/project"
mkdir -p "${PROJECT}" "${TEST_DIR}/home/.copilot"
printf '%s\n' '[user]' > "${TEST_DIR}/home/.gitconfig"
printf '%s\n' '{}' > "${TEST_DIR}/home/.copilot/config.json"
printf '%s\n' 'instructions' > "${TEST_DIR}/home/.copilot/copilot-instructions.md"

assert_output_contains "-m requires a value" "${LAUNCHER}" -m
pass "missing option values are rejected"

assert_output_contains "--engine must be podman or docker" \
    "${LAUNCHER}" --engine invalid -m "${TEST_DIR}"
pass "invalid engines are rejected"

assert_output_contains "GPG agent socket not found" \
    env HOME="${TEST_DIR}/home" GNUPGHOME="${TEST_DIR}/home/.gnupg" "${LAUNCHER}" -m "${TEST_DIR}" --gpg-agent
pass "--gpg-agent fails when GPG agent socket is missing"

assert_output_contains "SSH_AUTH_SOCK is not set to a valid socket" \
    env -u SSH_AUTH_SOCK HOME="${TEST_DIR}/home" "${LAUNCHER}" -m "${TEST_DIR}" --ssh-agent
pass "--ssh-agent fails when SSH_AUTH_SOCK is missing"

# --- Fake podman: always starts detached, always publishes port 65000 ----
FAKE_BIN="${TEST_DIR}/bin"
CAPTURE="${TEST_DIR}/run-args"
mkdir -p "${FAKE_BIN}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    '  volume)' \
    '    [ "${2:-}" = inspect ] && exit 1' \
    '    [ "${2:-}" = create ] && exit 0' \
    '    ;;' \
    '  port)' \
    '    echo "127.0.0.1:65000"' \
    '    exit 0' \
    '    ;;' \
    '  run)' \
    '    shift' \
    '    printf "%s\n" "$@" > "${CAPTURE}"' \
    '    echo fake-container-id' \
    '    exit 0' \
    '    ;;' \
    '  rm)' \
    '    exit 0' \
    '    ;;' \
    'esac' \
    'exit 1' > "${FAKE_BIN}/podman"
chmod 755 "${FAKE_BIN}/podman"

# --- Fake ssh: succeeds on the readiness ping (BatchMode=yes) immediately;
# the real interactive session's args are captured to SSH_CAPTURE.
SSH_CAPTURE="${TEST_DIR}/ssh-args"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for a in "$@"; do' \
    '  if [ "${a}" = "BatchMode=yes" ]; then exit 0; fi' \
    'done' \
    'printf "%s\n" "$@" > "${SSH_CAPTURE}"' \
    'exit 0' > "${FAKE_BIN}/ssh"
chmod 755 "${FAKE_BIN}/ssh"

assert_output_contains "no host Hunk runtime state was found" \
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --hunk-agent
pass "--hunk-agent fails when host Hunk runtime state is missing"

HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" >/dev/null

home_volume_line="$(grep -nE ':/home/copilot$' "${CAPTURE}" | head -n1 | cut -d: -f1)"
config_line="$(grep -nFx "${TEST_DIR}/home/.copilot/config.json:/home/copilot/.copilot-config-seed.json:ro" "${CAPTURE}" | cut -d: -f1)"
instructions_line="$(grep -nFx "${TEST_DIR}/home/.copilot/copilot-instructions.md:/home/copilot/.copilot/copilot-instructions.md:ro" "${CAPTURE}" | cut -d: -f1)"

[ -n "${home_volume_line}" ] || fail "state volume was not passed to the engine"
[ -n "${config_line}" ] || fail "read-only Copilot config seed mount was not passed"
[ -n "${instructions_line}" ] || fail "read-only instructions mount was not passed"
[ "${home_volume_line}" -lt "${config_line}" ] ||
    fail "state volume must precede the Copilot config mount"
[ "${home_volume_line}" -lt "${instructions_line}" ] ||
    fail "state volume must precede the instructions mount"
pass "state volume precedes nested read-only mounts"

grep -Fxq -- "-d" "${CAPTURE}" || fail "container is not started detached (-d)"
pass "container is always started detached"

[ -f "${SSH_CAPTURE}" ] || fail "launcher did not connect in over ssh"
grep -Fq "copilot@127.0.0.1" "${SSH_CAPTURE}" || fail "ssh session did not target copilot@127.0.0.1"
grep -Fq "IdentitiesOnly=yes" "${SSH_CAPTURE}" || fail "ssh session did not specify IdentitiesOnly=yes"
grep -Fq "cd ${PROJECT} &&" "${SSH_CAPTURE}" || fail "remote command did not cd into the project"
grep -Fq "exec copilot" "${SSH_CAPTURE}" || fail "remote command did not exec copilot"
! grep -Fq "HUNK_MCP_HOST=" "${SSH_CAPTURE}" || fail "Hunk forwarding should be disabled by default"
! grep -Fq "127.0.0.1:47657:127.0.0.1:47657" "${SSH_CAPTURE}" ||
    fail "Hunk tunnel should be disabled by default"
pass "launcher always connects in over ssh to run copilot"

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test --hunk-agent mounts Hunk's runtime state and exports broker settings
mkdir -p "${TEST_DIR}/home/.hunk/hunk-mcp/security-v1"

env HOME="${TEST_DIR}/home" HUNK_MCP_PORT=56789 CAPTURE="${CAPTURE}" \
    SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --hunk-agent >/dev/null

hunk_runtime_line="$(grep -nFx "${TEST_DIR}/home/.hunk/hunk-mcp:/home/copilot/.hunk/hunk-mcp:ro" "${CAPTURE}" | cut -d: -f1)"

[ -n "${hunk_runtime_line}" ] || fail "--hunk-agent did not mount host Hunk runtime state"
grep -Fq "XDG_RUNTIME_DIR=/home/copilot/.hunk" "${SSH_CAPTURE}" ||
    fail "--hunk-agent did not export XDG_RUNTIME_DIR"
grep -Fq "HUNK_MCP_HOST=127.0.0.1" "${SSH_CAPTURE}" ||
    fail "--hunk-agent did not export HUNK_MCP_HOST"
grep -Fq "HUNK_MCP_PORT=56789" "${SSH_CAPTURE}" ||
    fail "--hunk-agent did not pass through HUNK_MCP_PORT"
grep -Fq "127.0.0.1:56789:127.0.0.1:56789" "${SSH_CAPTURE}" ||
    fail "--hunk-agent did not tunnel the Hunk broker over SSH"
grep -Fq "ExitOnForwardFailure=yes" "${SSH_CAPTURE}" ||
    fail "--hunk-agent did not require the Hunk tunnel to be established"
pass "--hunk-agent mounts Hunk runtime state and exports broker settings"

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test default mount (no -m given) falls back to the current directory
(cd "${PROJECT}" && HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" >/dev/null)
physical_project="$(cd -- "${PROJECT}" && pwd -P)"
grep -nFx "${physical_project}:${PROJECT}" "${CAPTURE}" >/dev/null ||
    fail "no --mount given did not default to the current directory"
pass "no --mount given defaults to the current directory"

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test --gpg-agent with socket & pubring present
mkdir -p "${TEST_DIR}/home/.gnupg"
touch "${TEST_DIR}/home/.gnupg/pubring.kbx"
FAKE_GPGCONF="${FAKE_BIN}/gpgconf"
printf '%s\n' '#!/usr/bin/env bash' 'echo "'"${TEST_DIR}/home/.gnupg/S.gpg-agent"'"' > "${FAKE_GPGCONF}"
chmod 755 "${FAKE_GPGCONF}"

python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.bind('${TEST_DIR}/home/.gnupg/S.gpg-agent')"

env HOME="${TEST_DIR}/home" GNUPGHOME="${TEST_DIR}/home/.gnupg" CAPTURE="${CAPTURE}" \
    SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --gpg-agent >/dev/null

[ -f "${SSH_CAPTURE}" ] || fail "--gpg-agent did not invoke the real ssh session"

gpg_kbx_line="$(grep -nFx "${TEST_DIR}/home/.gnupg/pubring.kbx:/home/copilot/.copilot-container-bridge/pubring.kbx:ro" "${CAPTURE}" | cut -d: -f1)"
gpg_forward_line="$(grep -nFx "/home/copilot/.copilot-container-bridge/S.gpg-agent:${TEST_DIR}/home/.gnupg/S.gpg-agent" "${SSH_CAPTURE}" | cut -d: -f1)"
gnupghome_line="$(grep -nFq "GNUPGHOME=" "${SSH_CAPTURE}" && echo yes || echo "")"

[ -n "${gpg_kbx_line}" ] || fail "--gpg-agent did not mount pubring.kbx into the bridge dir"
[ -n "${gpg_forward_line}" ] || fail "--gpg-agent did not forward the gpg-agent socket over ssh"
[ -n "${gnupghome_line}" ] || fail "--gpg-agent did not export GNUPGHOME in the remote command"
grep -Fq "copilot@127.0.0.1" "${SSH_CAPTURE}" || fail "ssh session did not target copilot@127.0.0.1"
pass "--gpg-agent mounts public keyrings and forwards the agent socket over ssh"

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test --ssh-agent with socket and known_hosts present
mkdir -p "${TEST_DIR}/home/.ssh"
printf '%s\n' 'github.com ssh-ed25519 test-key' > "${TEST_DIR}/home/.ssh/known_hosts"
python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.bind('${TEST_DIR}/home/.ssh/S.ssh-agent')"

env HOME="${TEST_DIR}/home" SSH_AUTH_SOCK="${TEST_DIR}/home/.ssh/S.ssh-agent" CAPTURE="${CAPTURE}" \
    SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --ssh-agent >/dev/null

[ -f "${SSH_CAPTURE}" ] || fail "--ssh-agent did not invoke the real ssh session"

known_hosts_line="$(grep -nFx "${TEST_DIR}/home/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro" "${CAPTURE}" | cut -d: -f1)"
ssh_forward_line="$(grep -nFx "/home/copilot/.copilot-container-bridge/ssh-agent.sock:${TEST_DIR}/home/.ssh/S.ssh-agent" "${SSH_CAPTURE}" | cut -d: -f1)"
ssh_auth_sock_line="$(grep -nFq "SSH_AUTH_SOCK=" "${SSH_CAPTURE}" && echo yes || echo "")"

[ -n "${known_hosts_line}" ] || fail "--ssh-agent did not mount host known_hosts"
[ -n "${ssh_forward_line}" ] || fail "--ssh-agent did not forward the ssh-agent socket over ssh"
[ -n "${ssh_auth_sock_line}" ] || fail "--ssh-agent did not export SSH_AUTH_SOCK in the remote command"
pass "--ssh-agent mounts known_hosts and forwards the agent socket over ssh"

assert_output_contains "HOST_UID must be a numeric user ID" \
    env HOST_UID=invalid bash "${ENTRYPOINT}"
pass "invalid runtime UID is rejected"

# --- Readiness-timeout diagnostics: a broken/unready sshd should surface
# the last ssh error, not just a bare "timed out" message.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'echo "Permission denied (publickey)." >&2' \
    'exit 255' > "${FAKE_BIN}/ssh"
chmod 755 "${FAKE_BIN}/ssh"

readiness_output="$(HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" \
    COPILOT_CONTAINER_POLL_ATTEMPTS=2 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" 2>&1)" && fail "expected launcher to fail when ssh never becomes ready"
printf '%s\n' "${readiness_output}" | grep -Fq "timed out waiting for container's sshd to become ready" ||
    fail "readiness timeout did not report the expected message"
printf '%s\n' "${readiness_output}" | grep -Fq "Permission denied (publickey)." ||
    fail "readiness timeout did not surface the last ssh error"
pass "readiness timeout surfaces the last ssh error instead of a bare timeout"

echo "All shell tests passed."
