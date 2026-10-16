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
    'if [ -n "${ENGINE_CALLS:-}" ]; then printf "%s\n" "$*" >> "${ENGINE_CALLS}"; fi' \
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
    '  logs)' \
    '    echo "test container startup log" >&2' \
    '    if [ "${2:-}" = "-f" ]; then exec sleep 30; fi' \
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

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test that the host's TERM_PROGRAM/TERM_PROGRAM_VERSION are forwarded, so
# Copilot CLI's hyperlink detection still recognizes the host terminal.
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    PATH="${FAKE_BIN}:${PATH}" TERM_PROGRAM="ghostty" TERM_PROGRAM_VERSION="1.2.3" \
    "${LAUNCHER}" -m "${PROJECT}" >/dev/null

grep -Fq "TERM_PROGRAM=ghostty" "${SSH_CAPTURE}" || fail "TERM_PROGRAM was not forwarded over ssh"
grep -Fq "TERM_PROGRAM_VERSION=1.2.3" "${SSH_CAPTURE}" || fail "TERM_PROGRAM_VERSION was not forwarded over ssh"
pass "TERM_PROGRAM/TERM_PROGRAM_VERSION are forwarded to the remote session"

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test .tool-versions prompt: pending tools reported + "y" installs them
ASDF_SCRIPT="${ROOT_DIR}/lib/asdf-provision.sh"
printf '%s\n' 'nodejs 20.11.0' > "${PROJECT}/.tool-versions"
SSH_CALLS="${TEST_DIR}/ssh-calls"
rm -f "${SSH_CALLS}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for a in "$@"; do' \
    '  if [ "${a}" = "BatchMode=yes" ]; then exit 0; fi' \
    'done' \
    'printf "%s\n" "$*" >> "${SSH_CALLS}"' \
    'case "$*" in' \
    '  *"asdf-provision check"*) echo "nodejs 20.11.0" ;;' \
    'esac' \
    'exit 0' > "${FAKE_BIN}/ssh"
chmod 755 "${FAKE_BIN}/ssh"

printf 'y\n' | env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" -m "${PROJECT}" >/dev/null

grep -Fq "asdf-provision check" "${SSH_CALLS}" || fail ".tool-versions present did not trigger a pending-tools check"
grep -Fq "asdf-provision install" "${SSH_CALLS}" || fail "answering 'y' did not trigger asdf install"
pass ".tool-versions prompt checks pending tools and installs them on 'y'"

rm -f "${SSH_CALLS}"
printf 'n\n' | env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" -m "${PROJECT}" >/dev/null

grep -Fq "asdf-provision check" "${SSH_CALLS}" || fail ".tool-versions present did not trigger a pending-tools check"
! grep -Fq "asdf-provision install" "${SSH_CALLS}" || fail "answering 'n' should not trigger asdf install"
pass ".tool-versions prompt skips installing when declined"

rm -f "${SSH_CALLS}"

# --auto-install-tools skips the prompt and installs without stdin input
auto_install_output="$(env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" -m "${PROJECT}" --auto-install-tools </dev/null 2>&1 >/dev/null)"

grep -Fq "asdf-provision check" "${SSH_CALLS}" || fail "--auto-install-tools did not trigger a pending-tools check"
grep -Fq "asdf-provision install" "${SSH_CALLS}" || fail "--auto-install-tools did not install without prompting"
printf '%s\n' "${auto_install_output}" | grep -Fq "installing without prompting" ||
    fail "--auto-install-tools did not report that it is installing automatically"
pass "--auto-install-tools installs pending tools without prompting"

rm -f "${SSH_CALLS}" "${PROJECT}/.tool-versions"

# Unit-test the in-container helper script directly against a fake asdf
ASDF_PROJECT="${TEST_DIR}/asdf-project"
mkdir -p "${ASDF_PROJECT}"
printf '%s\n' 'nodejs 20.11.0' 'golang 1.22.1' > "${ASDF_PROJECT}/.tool-versions"
FAKE_ASDF_HOME="${TEST_DIR}/asdf-home"
mkdir -p "${FAKE_ASDF_HOME}"
PLUGINS_FILE="${FAKE_ASDF_HOME}/plugins"
INSTALLED_FILE="${FAKE_ASDF_HOME}/installed"
: > "${PLUGINS_FILE}"
printf '%s\n' 'nodejs 20.11.0' > "${INSTALLED_FILE}"
ASDF_CALLS="${TEST_DIR}/asdf-calls"
: > "${ASDF_CALLS}"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'echo "$*" >> "${ASDF_CALLS}"' \
    'case "$1" in' \
    '  plugin)' \
    '    case "$2" in' \
    '      list) cat "${PLUGINS_FILE}" ;;' \
    '      add) echo "$3" >> "${PLUGINS_FILE}" ;;' \
    '    esac' \
    '    ;;' \
    '  list)' \
    '    grep "^$2 " "${INSTALLED_FILE}" | cut -d" " -f2 ;;' \
    '  install) echo installed >> "${INSTALLED_FILE}" ;;' \
    'esac' \
    'exit 0' > "${FAKE_BIN}/asdf"
chmod 755 "${FAKE_BIN}/asdf"
printf '%s\n' 'nodejs' > "${PLUGINS_FILE}"

check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
printf '%s\n' "${check_output}" | grep -Fxq "golang 1.22.1" ||
    fail "check did not report the plugin that needs adding/installing"
! printf '%s\n' "${check_output}" | grep -Fxq "nodejs 20.11.0" ||
    fail "check reported an already-installed tool as pending"
pass "asdf-provision check reports only missing plugins/versions"

env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" install "${ASDF_PROJECT}"
grep -Fxq "plugin add golang" "${ASDF_CALLS}" || fail "install did not add the missing plugin"
grep -Fxq "install" "${ASDF_CALLS}" || fail "install did not run asdf install"
pass "asdf-provision install adds missing plugins and runs asdf install"

# `asdf list` prefixes the version selected by the project's own
# .tool-versions (which is always the pinned one, since `check`/`install`
# cd into the project dir first) with "*". The pending check must still
# recognize it as installed instead of re-prompting every run.
printf '%s\n' 'nodejs 20.11.0' > "${ASDF_PROJECT}/.tool-versions"
printf '%s\n' 'nodejs' > "${PLUGINS_FILE}"
printf '%s\n' 'nodejs *20.11.0' > "${INSTALLED_FILE}"
starred_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ -z "${starred_check_output}" ] ||
    fail "check reported a '*'-marked already-installed version as pending"
pass "asdf-provision check isn't fooled by asdf's '*' marker for the selected version"

# "system"/"path:..." are asdf's uninstallable pseudo-versions and must
# never be reported as pending (they'd otherwise re-prompt every run).
printf '%s\n' 'nodejs system' 'golang path:/opt/go' > "${ASDF_PROJECT}/.tool-versions"
system_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ -z "${system_check_output}" ] || fail "check reported 'system'/'path:' pseudo-versions as pending"
pass "asdf-provision check ignores 'system'/'path:' pseudo-versions"

assert_output_contains "HOST_UID must be a numeric user ID" \
    env HOST_UID=invalid bash "${ENTRYPOINT}"
pass "invalid runtime UID is rejected"

# Fail before any system mutation to exercise unexpected entrypoint errors.
printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "${FAKE_BIN}/mkdir"
chmod 755 "${FAKE_BIN}/mkdir"
entrypoint_status=0
entrypoint_output="$(env -u COPILOT_CONTAINER_DEBUG HOST_UID=1000 HOST_GID=1000 \
    PATH="${FAKE_BIN}:${PATH}" bash "${ENTRYPOINT}" 2>&1)" || entrypoint_status=$?
[ "${entrypoint_status}" -eq 42 ] || fail "entrypoint did not preserve the failing command's exit status"
printf '%s\n' "${entrypoint_output}" | grep -Fq "entrypoint failed at line" ||
    fail "entrypoint did not report the failure location"
pass "entrypoint reports unexpected failures and preserves their exit status"

debug_entrypoint_log="${TEST_DIR}/debug-entrypoint-log"
# macOS sleep does not support the Linux "infinity" argument.
printf '%s\n' '#!/usr/bin/env bash' 'exec /bin/sleep 30' > "${FAKE_BIN}/sleep"
chmod 755 "${FAKE_BIN}/sleep"
env COPILOT_CONTAINER_DEBUG=1 HOST_UID=1000 HOST_GID=1000 PATH="${FAKE_BIN}:${PATH}" \
    bash "${ENTRYPOINT}" > "${debug_entrypoint_log}" 2>&1 &
entrypoint_pid=$!
for _ in $(seq 1 40); do
    if grep -Fq "keeping debug container running for inspection" "${debug_entrypoint_log}"; then
        break
    fi
    sleep 0.05
done
entrypoint_alive=0
kill -0 "${entrypoint_pid}" 2>/dev/null && entrypoint_alive=1
kill "${entrypoint_pid}" 2>/dev/null || true
wait "${entrypoint_pid}" 2>/dev/null || true
[ "${entrypoint_alive}" -eq 1 ] || fail "debug entrypoint did not remain alive after failure"
grep -Fq "entrypoint exited (status 42)" "${debug_entrypoint_log}" ||
    fail "debug entrypoint did not report the original failure status"
rm -f "${FAKE_BIN}/mkdir" "${FAKE_BIN}/sleep"
pass "debug entrypoint stays running after startup failure"

# --- Readiness-timeout diagnostics: a broken/unready sshd should surface
# the last ssh error, not just a bare "timed out" message.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'echo "Permission denied (publickey)." >&2' \
    'exit 255' > "${FAKE_BIN}/ssh"
chmod 755 "${FAKE_BIN}/ssh"

ENGINE_CALLS="${TEST_DIR}/engine-calls"
readiness_output="$(HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" ENGINE_CALLS="${ENGINE_CALLS}" \
    COPILOT_CONTAINER_POLL_ATTEMPTS=2 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" 2>&1)" && fail "expected launcher to fail when ssh never becomes ready"
printf '%s\n' "${readiness_output}" | grep -Fq "timed out waiting for container's sshd to become ready" ||
    fail "readiness timeout did not report the expected message"
printf '%s\n' "${readiness_output}" | grep -Fq "Permission denied (publickey)." ||
    fail "readiness timeout did not surface the last ssh error"
pass "readiness timeout surfaces the last ssh error instead of a bare timeout"
printf '%s\n' "${readiness_output}" | grep -Fq "test container startup log" ||
    fail "startup failure did not print container logs"
grep -q '^rm -f copilot-container-' "${ENGINE_CALLS}" ||
    fail "normal startup failure did not remove the container"
! grep -Fxq -- "--rm" "${CAPTURE}" ||
    fail "engine auto-removal would discard logs before diagnostics"
pass "normal startup failure prints container logs before cleanup"

: > "${ENGINE_CALLS}"
debug_status=0
debug_output="$(HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" ENGINE_CALLS="${ENGINE_CALLS}" \
    COPILOT_CONTAINER_POLL_ATTEMPTS=2 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --debug -m "${PROJECT}" 2>&1)" || debug_status=$?
[ "${debug_status}" -ne 0 ] || fail "debug mode hid the SSH startup failure"
grep -Fxq "COPILOT_CONTAINER_DEBUG=1" "${CAPTURE}" ||
    fail "debug mode did not enable entrypoint diagnostics"
! grep -q '^rm ' "${ENGINE_CALLS}" || fail "debug mode removed the container"
grep -q '^logs -f copilot-container-' "${ENGINE_CALLS}" ||
    fail "debug mode did not follow container logs"
printf '%s\n' "${debug_output}" | grep -Fq "test container startup log" ||
    fail "debug mode did not stream container logs"
for expected in "debug container retained:" "Logs:" "exec -it" "/bin/bash" "Cleanup:"; do
    printf '%s\n' "${debug_output}" | grep -Fq "${expected}" ||
        fail "debug mode did not print inspection instructions: ${expected}"
done
pass "debug mode streams logs and retains the failed container with inspection commands"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${FAKE_BIN}/ssh"
: > "${ENGINE_CALLS}"
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" ENGINE_CALLS="${ENGINE_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" --debug -m "${PROJECT}" >/dev/null 2>&1
! grep -q '^rm ' "${ENGINE_CALLS}" || fail "debug mode removed the container after a successful session"
pass "debug mode also retains the container after a successful session"

echo "All shell tests passed."
