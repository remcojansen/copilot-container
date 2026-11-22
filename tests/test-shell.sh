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
assert_output_contains "--mount-ro requires a value" "${LAUNCHER}" --mount-ro
pass "missing option values are rejected"

assert_output_contains "--state-volume requires a value" "${LAUNCHER}" --state-volume
assert_output_contains "--state-volume must start with a letter or digit" \
    "${LAUNCHER}" --state-volume 'invalid/name'
assert_output_contains "--state-volume must start with a letter or digit" \
    "${LAUNCHER}" --state-volume '-invalid'
pass "invalid state-volume names are rejected"

assert_output_contains "--engine must be podman or docker" \
    "${LAUNCHER}" --engine invalid -m "${TEST_DIR}"
pass "invalid engines are rejected"

assert_output_contains "GPG agent socket not found" \
    env HOME="${TEST_DIR}/home" GNUPGHOME="${TEST_DIR}/home/.gnupg" "${LAUNCHER}" -m "${TEST_DIR}" --gpg-agent
pass "--gpg-agent fails when GPG agent socket is missing"

assert_output_contains "SSH_AUTH_SOCK is not set to a valid socket" \
    env -u SSH_AUTH_SOCK HOME="${TEST_DIR}/home" "${LAUNCHER}" -m "${TEST_DIR}" --ssh-agent
pass "--ssh-agent fails when SSH_AUTH_SOCK is missing"

# --- Fake podman: starts containers and publishes port 65000 -------------
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
    '  create)' \
    '    shift' \
    '    printf "%s\n" "$@" > "${CAPTURE}"' \
    '    [ "${1:-}" = "--name" ] || exit 1' \
    '    name="$2"' \
    '    if [ "${FAKE_CREATE_FAIL:-0}" != 0 ]; then echo unexpected-output; exit 1; fi' \
    '    if [ -n "${FAKE_ENGINE_STATE:-}" ]; then' \
    '      mkdir "${FAKE_ENGINE_STATE}/${name}" 2>/dev/null || { echo "name already in use" >&2; exit 1; }' \
    '    fi' \
    '    echo "id-${name}"' \
    '    exit 0' \
    '    ;;' \
    '  container)' \
    '    [ "${2:-}" = inspect ] && [ -n "${FAKE_ENGINE_STATE:-}" ] && [ -d "${FAKE_ENGINE_STATE}/${3:-}" ]' \
    '    exit $?' \
    '    ;;' \
    '  start)' \
    '    [ "${FAKE_START_FAIL:-0}" = 0 ] || exit 1' \
    '    exit 0' \
    '    ;;' \
    '  rm)' \
    '    if [ -n "${FAKE_ENGINE_STATE:-}" ]; then rmdir "${FAKE_ENGINE_STATE}/${3#id-}"; fi' \
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
    'case "$*" in *"asdf-provision check"*) exit 0 ;; esac' \
    'printf "%s\n" "$@" > "${SSH_CAPTURE}"' \
    'if [ -n "${SSH_HOLD:-}" ]; then' \
    '  : > "${SSH_READY}"' \
    '  read -r _ < "${SSH_HOLD}"' \
    'fi' \
    'exit 0' > "${FAKE_BIN}/ssh"
chmod 755 "${FAKE_BIN}/ssh"

assert_output_contains "no host Hunk runtime state was found" \
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --hunk-agent
pass "--hunk-agent fails when host Hunk runtime state is missing"

INITIAL_ENGINE_CALLS="${TEST_DIR}/initial-engine-calls"
HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    ENGINE_CALLS="${INITIAL_ENGINE_CALLS}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" >/dev/null

home_volume_line="$(grep -nE ':/home/copilot:z$' "${CAPTURE}" | head -n1 | cut -d: -f1)"
config_line="$(grep -nFx "${TEST_DIR}/home/.copilot/config.json:/home/copilot/.copilot-config-seed.json:ro" "${CAPTURE}" | cut -d: -f1)"
instructions_line="$(grep -nFx "${TEST_DIR}/home/.copilot/copilot-instructions.md:/home/copilot/.copilot/copilot-instructions.md:ro" "${CAPTURE}" | cut -d: -f1)"

[ -n "${home_volume_line}" ] || fail "state volume was not passed with shared SELinux relabeling (:z)"
[ -n "${config_line}" ] || fail "read-only Copilot config seed mount was not passed"
[ -n "${instructions_line}" ] || fail "read-only instructions mount was not passed"
[ "${home_volume_line}" -lt "${config_line}" ] ||
    fail "state volume must precede the Copilot config mount"
[ "${home_volume_line}" -lt "${instructions_line}" ] ||
    fail "state volume must precede the instructions mount"
pass "state volume precedes nested read-only mounts"

grep -q '^start id-copilot-container-' "${INITIAL_ENGINE_CALLS}" ||
    fail "created container was not started"
pass "container is started after creation"

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

SUMMARY="${TEST_DIR}/startup-summary"
SECOND_PROJECT="${TEST_DIR}/second-project"
mkdir -p "${SECOND_PROJECT}"
env HOME="${TEST_DIR}/home" GH_TOKEN="test-secret-token" CAPTURE="${CAPTURE}" \
    SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" -m "${SECOND_PROJECT}:/workspace/other" \
    -- --model test-secret-argument >/dev/null 2>"${SUMMARY}"

for expected in \
    "Engine: podman" "Image: copilot-container" "Working directory: ${PROJECT}" \
    "State volume: copilot-container_" "${PROJECT} -> ${PROJECT}" \
    "${SECOND_PROJECT} -> /workspace/other" \
    "${TEST_DIR}/home/.gitconfig:/home/copilot/.gitconfig:ro" \
    "- disabled  GPG agent" "- disabled  SSH agent" "- disabled  Hunk" "GitHub token: available"; do
    grep -Fq -- "${expected}" "${SUMMARY}" || fail "startup summary did not show: ${expected}"
done
! grep -Fq "test-secret-token" "${SUMMARY}" || fail "startup summary exposed the GitHub token"
! grep -Fq "test-secret-argument" "${SUMMARY}" || fail "startup summary exposed Copilot arguments"
! grep -Fq $'\033' "${SUMMARY}" || fail "redirected startup summary contains terminal color codes"
! grep -Fq "Press Enter" "${SUMMARY}" || fail "non-interactive run prompted to continue"
pass "startup summary shows effective configuration without secrets"

env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --mount-ro "${PROJECT}:/workspace/reference" -m "${SECOND_PROJECT}:/workspace/work" \
    >/dev/null 2>"${SUMMARY}"
grep -Fxq "${PROJECT}:/workspace/reference:ro" "${CAPTURE}" ||
    fail "read-only mount did not include the engine's ro option"
grep -Fxq "${SECOND_PROJECT}:/workspace/work" "${CAPTURE}" ||
    fail "read-write mount changed unexpectedly"
grep -Fq 'Working directory: /workspace/reference' "${SUMMARY}" ||
    fail "read-only first mount was not the working directory"
grep -Fq "read-only  ${PROJECT} -> /workspace/reference" "${SUMMARY}" ||
    fail "summary did not show the read-only project"
grep -Fq "read-write  ${SECOND_PROJECT} -> /workspace/work" "${SUMMARY}" ||
    fail "summary did not show the read-write project"
grep -Fq 'cd /workspace/reference &&' "${SSH_CAPTURE}" ||
    fail "read-only first mount was not used as the working directory"
pass "mixed mounts preserve order, access modes and primary directory"

env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --mount-ro "${PROJECT}" >/dev/null 2>"${SUMMARY}"
grep -Fxq "${PROJECT}:${PROJECT}:ro" "${CAPTURE}" ||
    fail "read-only mount did not default to the host path"
pass "read-only mount defaults to the host path"

env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --mount-ro "${SECOND_PROJECT}:/workspace/reference" \
    >/dev/null 2>"${SUMMARY}"
grep -Fxq "${SECOND_PROJECT}:/workspace/reference:ro" "${CAPTURE}" ||
    fail "read-only mount after a writable mount lost its mode"
grep -Fq "Working directory: ${PROJECT}" "${SUMMARY}" ||
    fail "read-write first mount was not the working directory"
pass "read-only mount after a writable mount preserves its mode"

mkdir -p "${PROJECT}/nested"
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --mount-ro "${PROJECT}:/workspace" -m "${PROJECT}/nested:/workspace/nested" \
    >/dev/null 2>"${SUMMARY}"
grep -Fxq "${PROJECT}:/workspace:ro" "${CAPTURE}" ||
    fail "overlapping read-only mount was not passed through"
grep -Fxq "${PROJECT}/nested:/workspace/nested" "${CAPTURE}" ||
    fail "overlapping read-write mount was not passed through"
pass "overlapping mounts are passed to the container engine"

if command -v script >/dev/null 2>&1 && script --version 2>/dev/null | grep -q 'util-linux'; then
    tty_cmd="$(printf '%q ' "${LAUNCHER}" -m "${PROJECT}")"
    tty_output="$(printf 'x\n' | env HOME="${TEST_DIR}/home" TERM=xterm NO_COLOR= CAPTURE="${CAPTURE}" \
        SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
        script -q -e -c "${tty_cmd}" /dev/null)"
    [[ "${tty_output}" == *$'\033[36m'* && "${tty_output}" == *$'\033[0m'* ]] ||
        fail "terminal startup summary did not enable and reset color"
    [[ "${tty_output}" == *"Press Enter to start Copilot"* ]] ||
        fail "interactive startup did not prompt to continue"
    no_color_output="$(printf 'x\n' | env HOME="${TEST_DIR}/home" TERM=xterm NO_COLOR=1 CAPTURE="${CAPTURE}" \
        SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
        script -q -e -c "${tty_cmd}" /dev/null)"
    [[ "${no_color_output}" != *$'\033'* ]] || fail "NO_COLOR did not disable terminal color"
    dumb_output="$(printf 'x\n' | env HOME="${TEST_DIR}/home" TERM=dumb NO_COLOR= CAPTURE="${CAPTURE}" \
        SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
        script -q -e -c "${tty_cmd}" /dev/null)"
    [[ "${dumb_output}" != *$'\033'* ]] || fail "dumb terminal received color codes"
    pass "startup summary uses terminal color and respects NO_COLOR"

    tty_input="${TEST_DIR}/tty-input"
    tty_log="${TEST_DIR}/tty-log"
    tty_engine_calls="${TEST_DIR}/tty-engine-calls"
    : > "${tty_engine_calls}"
    mkfifo "${tty_input}"
    exec 9<> "${tty_input}"
    env HOME="${TEST_DIR}/home" TERM=xterm CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
        ENGINE_CALLS="${tty_engine_calls}" PATH="${FAKE_BIN}:${PATH}" \
        script -q -f -e -c "${tty_cmd}" /dev/null < "${tty_input}" > "${tty_log}" 2>&1 &
    tty_pid=$!
    for _ in $(seq 1 100); do
        grep -Fq "Press Enter to start Copilot" "${tty_log}" && break
        sleep 0.05
    done
    if ! grep -Fq "Press Enter to start Copilot" "${tty_log}" ||
        grep -q '^create ' "${tty_engine_calls}"; then
        kill "${tty_pid}" 2>/dev/null || true
        wait "${tty_pid}" 2>/dev/null || true
        fail "interactive launcher did not wait before starting the container"
    fi
    printf '\n' >&9
    wait "${tty_pid}" || fail "interactive launcher did not continue after Enter"
    exec 9>&-
    grep -q '^create ' "${tty_engine_calls}" || fail "Enter did not start the container"
    pass "interactive startup waits for Enter before starting the container"
fi

rm -f "${SSH_CAPTURE}" "${CAPTURE}"

# Test --hunk-agent mounts Hunk's runtime state and exports broker settings
mkdir -p "${TEST_DIR}/home/.hunk/hunk-mcp/security-v1"

env HOME="${TEST_DIR}/home" HUNK_MCP_PORT=56789 CAPTURE="${CAPTURE}" \
    SSH_CAPTURE="${SSH_CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" --hunk-agent >/dev/null 2>"${SUMMARY}"

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
grep -Fq "✓ enabled  Hunk" "${SUMMARY}" || fail "startup summary did not show enabled Hunk integration"
grep -Fq "${TEST_DIR}/home/.hunk/hunk-mcp:/home/copilot/.hunk/hunk-mcp:ro" "${SUMMARY}" ||
    fail "startup summary did not show the Hunk mount"
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

SECOND_PROJECT="${TEST_DIR}/second-project"
mkdir -p "${SECOND_PROJECT}"
VOLUME_CALLS="${TEST_DIR}/volume-calls"
for project in "${PROJECT}" "${SECOND_PROJECT}"; do
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
        ENGINE_CALLS="${VOLUME_CALLS}" PATH="${FAKE_BIN}:${PATH}" \
        "${LAUNCHER}" --state-volume my-workspace -m "${project}" >/dev/null
    grep -Fxq "my-workspace:/home/copilot:z" "${CAPTURE}" ||
        fail "explicit state volume was not used for ${project}"
done
grep -Fxq "volume inspect my-workspace" "${VOLUME_CALLS}" ||
    fail "explicit state volume was not inspected"
grep -Fxq "volume create my-workspace" "${VOLUME_CALLS}" ||
    fail "missing explicit state volume was not created"
pass "explicit state volume is independent of the primary project"

ENGINE_STATE="${TEST_DIR}/engine-state"
ENGINE_CALLS="${TEST_DIR}/concurrent-engine-calls"
SSH_HOLD="${TEST_DIR}/ssh-hold"
SSH_READY="${TEST_DIR}/ssh-ready"
mkdir -p "${ENGINE_STATE}"
mkfifo "${SSH_HOLD}"
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" ENGINE_CALLS="${ENGINE_CALLS}" \
    SSH_HOLD="${SSH_HOLD}" SSH_READY="${SSH_READY}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --state-volume shared -m "${PROJECT}" >"${TEST_DIR}/first-launch" 2>&1 &
first_pid=$!
for _ in $(seq 1 200); do
    [ -f "${SSH_READY}" ] && break
    kill -0 "${first_pid}" 2>/dev/null || break
    sleep 0.05
done
if [ ! -f "${SSH_READY}" ]; then
    kill "${first_pid}" 2>/dev/null || true
    wait "${first_pid}" 2>/dev/null || true
    fail "first concurrent session did not start"
fi
first_name="$(sed -n '2p' "${CAPTURE}")"
: > "${ENGINE_CALLS}"
conflict_status=0
conflict_output="$(env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" ENGINE_CALLS="${ENGINE_CALLS}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --state-volume shared -m "${SECOND_PROJECT}" 2>&1)" || conflict_status=$?
other_status=0
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" ENGINE_CALLS="${ENGINE_CALLS}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --state-volume other -m "${PROJECT}" >/dev/null 2>&1 || other_status=$?
first_still_exists=0
[ -d "${ENGINE_STATE}/${first_name}" ] && first_still_exists=1
removed_by_competitor=0
grep -Fxq "rm -f id-${first_name}" "${ENGINE_CALLS}" && removed_by_competitor=1
printf 'continue\n' > "${SSH_HOLD}"
wait "${first_pid}" || fail "first concurrent session failed"
[ "${conflict_status}" -ne 0 ] || fail "same-volume concurrent launch succeeded"
printf '%s\n' "${conflict_output}" | grep -Fq "container for state volume shared already exists" ||
    fail "same-volume conflict did not explain the existing container"
printf '%s\n' "${conflict_output}" | grep -Fq "Inspect:" ||
    fail "same-volume conflict did not provide inspection instructions"
[ "${other_status}" -eq 0 ] || fail "different volume could not start concurrently"
[ "${first_still_exists}" -eq 1 ] || fail "competing launch removed the first container"
[ "${removed_by_competitor}" -eq 0 ] || fail "competing launch attempted to remove the first container"
[ ! -d "${ENGINE_STATE}/${first_name}" ] || fail "first session did not clean up its container"
pass "same-volume launches conflict without affecting other containers"

env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" ENGINE_CALLS="${ENGINE_CALLS}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --debug --state-volume retained -m "${PROJECT}" >/dev/null 2>&1
retained_name="$(sed -n '2p' "${CAPTURE}")"
[ -d "${ENGINE_STATE}/${retained_name}" ] || fail "debug container was not retained"
: > "${ENGINE_CALLS}"
assert_output_contains "container for state volume retained already exists" \
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" ENGINE_CALLS="${ENGINE_CALLS}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" --state-volume retained -m "${PROJECT}"
[ -d "${ENGINE_STATE}/${retained_name}" ] || fail "conflict removed retained debug container"
! grep -q '^rm ' "${ENGINE_CALLS}" || fail "conflict attempted to remove retained debug container"
rmdir "${ENGINE_STATE}/${retained_name}"
pass "retained debug containers reserve their state volume"

: > "${ENGINE_CALLS}"
start_status=0
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" FAKE_START_FAIL=1 ENGINE_CALLS="${ENGINE_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" --state-volume broken -m "${PROJECT}" \
    >/dev/null 2>&1 || start_status=$?
[ "${start_status}" -ne 0 ] || fail "engine start failure was ignored"
failed_name="$(sed -n '2p' "${CAPTURE}")"
grep -Fxq "rm -f id-${failed_name}" "${ENGINE_CALLS}" ||
    fail "start failure did not remove the newly created container by ID"
[ ! -d "${ENGINE_STATE}/${failed_name}" ] || fail "start failure left the container behind"
pass "start failures clean up only the created container"

: > "${ENGINE_CALLS}"
debug_start_status=0
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" FAKE_START_FAIL=1 ENGINE_CALLS="${ENGINE_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" --debug --state-volume broken -m "${PROJECT}" \
    >/dev/null 2>&1 || debug_start_status=$?
failed_name="$(sed -n '2p' "${CAPTURE}")"
[ "${debug_start_status}" -ne 0 ] || fail "debug mode hid the engine start failure"
[ -d "${ENGINE_STATE}/${failed_name}" ] || fail "debug mode did not retain the failed container"
! grep -q '^rm ' "${ENGINE_CALLS}" || fail "debug mode removed the failed container"
rmdir "${ENGINE_STATE}/${failed_name}"
pass "debug mode retains a container that fails to start"

: > "${ENGINE_CALLS}"
create_status=0
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CAPTURE="${SSH_CAPTURE}" \
    FAKE_ENGINE_STATE="${ENGINE_STATE}" FAKE_CREATE_FAIL=1 ENGINE_CALLS="${ENGINE_CALLS}" \
    PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" --state-volume broken -m "${PROJECT}" \
    >/dev/null 2>&1 || create_status=$?
[ "${create_status}" -ne 0 ] || fail "engine create failure was ignored"
! grep -q '^rm ' "${ENGINE_CALLS}" || fail "create failure attempted to remove a container"
pass "create failures never remove a container"

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
    '  *"asdf-provision check"*)' \
    '    [ "${FAKE_OLD_HELPER:-0}" = 0 ] || { echo "unknown mode" >&2; exit 2; }' \
    '    if [ "${FAKE_ASDF_EMPTY:-0}" = 1 ]; then exit 0; fi' \
    '    if [ "${FAKE_ASDF_MULTI:-0}" = 1 ]; then' \
    '      case "$*" in' \
    '        *"/workspace/api"*) printf "%s\n" "nodejs 20.11.0" "ruby 3.2.0" ;;' \
    '        *"/workspace/web"*) echo "nodejs 22.0.0" ;;' \
    '        *"/workspace/reference"*)' \
    '          [ "${FAKE_CHECK_FAIL:-0}" = 0 ] || { echo "check failed" >&2; exit 42; }' \
    '          echo "golang 1.22.1" ;;' \
    '      esac' \
    '    else echo "nodejs 20.11.0"; fi' \
    '    ;;' \
    'esac' \
    'exit 0' > "${FAKE_BIN}/ssh"
chmod 755 "${FAKE_BIN}/ssh"

if command -v script >/dev/null 2>&1 && script --version 2>/dev/null | grep -q 'util-linux'; then
    : > "${SSH_CALLS}"
    : > "${tty_log}"
    exec 9<> "${tty_input}"
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
        PATH="${FAKE_BIN}:${PATH}" script -q -f -e -c "${tty_cmd}" /dev/null \
        < "${tty_input}" > "${tty_log}" 2>&1 &
    tty_pid=$!
    for _ in $(seq 1 100); do
        grep -Fq "Press Enter to start Copilot" "${tty_log}" && break
        sleep 0.05
    done
    printf 'x\n' >&9
    for _ in $(seq 1 100); do
        grep -Fq "Install/update them now via asdf?" "${tty_log}" && break
        sleep 0.05
    done
    if ! grep -Fq "Install/update them now via asdf?" "${tty_log}" ||
        ! kill -0 "${tty_pid}" 2>/dev/null; then
        kill "${tty_pid}" 2>/dev/null || true
        wait "${tty_pid}" 2>/dev/null || true
        fail "tool-install prompt did not wait for a separate answer"
    fi
    printf 'y\n' >&9
    wait "${tty_pid}" || fail "interactive tool installation failed"
    exec 9>&-
    grep -Fq "asdf-provision install" "${SSH_CALLS}" ||
        fail "interactive tool-install answer was not honored"
    pass "startup confirmation does not consume the tool-install answer"
fi

rm -f "${SSH_CALLS}"
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

REFERENCE_PROJECT="${TEST_DIR}/reference project"
EMPTY_PROJECT="${TEST_DIR}/empty-project"
mkdir -p "${REFERENCE_PROJECT}" "${EMPTY_PROJECT}"
multi_mounts=(
    -m "${PROJECT}:/workspace/api"
    -m "${SECOND_PROJECT}:/workspace/web"
    --mount-ro "${REFERENCE_PROJECT}:/workspace/reference docs"
    -m "${EMPTY_PROJECT}:/workspace/empty"
)
: > "${SSH_CALLS}"
multi_output="$(printf 'y\n' | env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_ASDF_MULTI=1 PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" "${multi_mounts[@]}" 2>&1)"
for project_path in /workspace/api /workspace/web '/workspace/reference\ docs' /workspace/empty; do
    grep -Fq "asdf-provision check-plan ${project_path}" "${SSH_CALLS}" ||
        fail "multi-project check skipped ${project_path}"
done
grep -Fq -- "-n -p " "${SSH_CALLS}" || fail "tool checks did not preserve launcher input"
for project_path in /workspace/api /workspace/web '/workspace/reference\ docs'; do
    printf '%s\n' "${multi_output}" | grep -Fq "missing tools in ${project_path}:" ||
        fail "missing tools were not grouped under ${project_path}"
    grep -Fq "asdf-provision install ${project_path}" "${SSH_CALLS}" ||
        fail "multi-project install skipped ${project_path}"
done
! grep -Fq "asdf-provision install /workspace/empty" "${SSH_CALLS}" ||
    fail "multi-project install included a project with no missing tools"
for version in "nodejs 20.11.0" "nodejs 22.0.0" "golang 1.22.1"; do
    printf '%s\n' "${multi_output}" | grep -Fq "${version}" ||
        fail "multi-project summary omitted ${version}"
done
quoted_api_plan="$(printf '%q' $'nodejs 20.11.0\nruby 3.2.0')"
grep -Fq "asdf-provision install /workspace/api ${quoted_api_plan}" "${SSH_CALLS}" ||
    fail "multi-project install did not receive the approved tool list"
pass "one confirmation installs missing tools across writable and read-only mounts"

: > "${SSH_CALLS}"
printf 'n\n' | env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_ASDF_MULTI=1 PATH="${FAKE_BIN}:${PATH}" "${LAUNCHER}" "${multi_mounts[@]}" >/dev/null 2>&1
! grep -Fq "asdf-provision install" "${SSH_CALLS}" ||
    fail "declining multi-project provisioning installed tools"
pass "declining multi-project provisioning skips all installs"

: > "${SSH_CALLS}"
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_ASDF_MULTI=1 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" "${multi_mounts[@]}" </dev/null >/dev/null 2>&1
! grep -Fq "asdf-provision install" "${SSH_CALLS}" ||
    fail "non-interactive provisioning installed tools without opt-in"
pass "non-interactive multi-project provisioning requires opt-in"

: > "${SSH_CALLS}"
env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_ASDF_MULTI=1 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" "${multi_mounts[@]}" --auto-install-tools </dev/null >/dev/null 2>&1
for project_path in /workspace/api /workspace/web '/workspace/reference\ docs'; do
    grep -Fq "asdf-provision install ${project_path}" "${SSH_CALLS}" ||
        fail "automatic provisioning skipped ${project_path}"
done
pass "--auto-install-tools covers every mounted project"

: > "${SSH_CALLS}"
empty_output="$(env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_ASDF_EMPTY=1 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" "${multi_mounts[@]}" </dev/null 2>&1)"
! printf '%s\n' "${empty_output}" | grep -Fq "missing tools in" ||
    fail "empty tool checks reported missing tools"
! grep -Fq "asdf-provision install" "${SSH_CALLS}" ||
    fail "empty tool checks triggered an install"
pass "projects without missing tools do not trigger provisioning"

: > "${SSH_CALLS}"
assert_output_contains 'could not check tool versions in /workspace/reference\ docs' \
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_ASDF_MULTI=1 FAKE_CHECK_FAIL=1 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" "${multi_mounts[@]}" --auto-install-tools
! grep -Fq "asdf-provision install" "${SSH_CALLS}" ||
    fail "failed tool check triggered partial installation"
pass "tool check failures stop before installing anything"

: > "${SSH_CALLS}"
assert_output_contains "ensure the container image is up to date" \
    env HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" SSH_CALLS="${SSH_CALLS}" \
    FAKE_OLD_HELPER=1 PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" "${multi_mounts[@]}" --auto-install-tools
! grep -Fq "asdf-provision install" "${SSH_CALLS}" ||
    fail "older helper triggered unsafe broad installation"
pass "older container images cannot trigger broad installation"

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
    '      add) [ "$3" = -- ] && echo "$4" >> "${PLUGINS_FILE}" ;;' \
    '    esac' \
    '    ;;' \
    '  where)' \
    '    [ "$2" = -- ] || exit 2' \
    '    [ "${FAKE_WHERE_ERROR:-0}" = 0 ] || { echo "unexpected asdf error" >&2; exit 1; }' \
    '    grep -Fxq "$3" "${PLUGINS_FILE}" || { echo "No such plugin: $3" >&2; exit 1; }' \
    '    grep -Fxq "$3 $4" "${INSTALLED_FILE}" || { echo "Version not installed" >&2; exit 1; }' \
    '    ;;' \
    '  install)' \
    '    [ "${2:-}" = -- ] || exit 2' \
    '    printf "%s %s\n" "$3" "$4" >> "${INSTALLED_FILE}" ;;' \
    'esac' \
    'exit 0' > "${FAKE_BIN}/asdf"
chmod 755 "${FAKE_BIN}/asdf"
printf '%s\n' 'nodejs' > "${PLUGINS_FILE}"

check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check-plan "${ASDF_PROJECT}")"
printf '%s\n' "${check_output}" | grep -Fxq "golang 1.22.1" ||
    fail "check did not report the plugin that needs adding/installing"
! printf '%s\n' "${check_output}" | grep -Fxq "nodejs 20.11.0" ||
    fail "check reported an already-installed tool as pending"
pass "asdf-provision check reports only missing plugins/versions"

printf '%s\n' 'nodejs system 20.11.0 22.0.0 path:/opt/node # fallback' > "${ASDF_PROJECT}/.tool-versions"
fallback_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ "${fallback_check_output}" = "nodejs 22.0.0" ] ||
    fail "check did not report only the missing fallback version"
printf 'nodejs 20.11.0 22.0.0# fallback\n#golang 100\ngolang 1.22.1# comment' \
    > "${ASDF_PROJECT}/.tool-versions"
comment_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ "${comment_check_output}" = $'nodejs 22.0.0\ngolang 1.22.1' ] ||
    fail "check did not strip inline comments before parsing versions"
pass "asdf-provision strips inline comments before parsing versions"

printf 'nodejs 20.11.0 \r\ngolang 1.22.1 \t \r\n' > "${ASDF_PROJECT}/.tool-versions"
crlf_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ "${crlf_check_output}" = "golang 1.22.1" ] ||
    fail "check reported an empty version after trailing whitespace and CRLF"
pass "asdf-provision ignores trailing whitespace before CRLF"

printf '%s\n' 'nodejs 20.11.0' 'golang 1.22.1' > "${ASDF_PROJECT}/.tool-versions"
pass "asdf-provision checks every installable version on each line"

# Change the file after the check: installation must use the approved list.
printf '%s\n' 'nodejs 99.0.0' > "${ASDF_PROJECT}/.tool-versions"
env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" install "${ASDF_PROJECT}" "${check_output}"
grep -Fxq "plugin add -- golang" "${ASDF_CALLS}" || fail "install did not add the missing plugin"
grep -Fxq "install -- golang 1.22.1" "${ASDF_CALLS}" || fail "install did not target the approved version"
! grep -Fq "install -- nodejs 99.0.0" "${ASDF_CALLS}" ||
    fail "install used an unapproved version from the changed file"
pass "asdf-provision installs only approved versions"

printf '%s\n' 'nodejs 20.11.0' > "${ASDF_PROJECT}/.tool-versions"
printf '%s\n' 'nodejs' > "${PLUGINS_FILE}"
printf '%s\n' 'nodejs 20x11x0' > "${INSTALLED_FILE}"
exact_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ "${exact_check_output}" = "nodejs 20.11.0" ] ||
    fail "check confused a similarly named version with the requested version"
pass "asdf-provision checks exact versions"

assert_output_contains "asdf could not check" \
    env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" FAKE_WHERE_ERROR=1 \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}"
pass "asdf-provision reports unexpected asdf errors"

printf '%s\n' 'nodejs latest:20' > "${ASDF_PROJECT}/.tool-versions"
assert_output_contains "pin a specific version" \
    env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}"
pass "asdf-provision rejects dynamic latest versions"

# "system"/"path:..." are asdf's uninstallable pseudo-versions and must
# never be reported as pending (they'd otherwise re-prompt every run).
printf '%s\n' 'nodejs system' 'golang path:/opt/go' > "${ASDF_PROJECT}/.tool-versions"
system_check_output="$(env PATH="${FAKE_BIN}:${PATH}" PLUGINS_FILE="${PLUGINS_FILE}" \
    INSTALLED_FILE="${INSTALLED_FILE}" ASDF_CALLS="${ASDF_CALLS}" \
    bash "${ASDF_SCRIPT}" check "${ASDF_PROJECT}")"
[ -z "${system_check_output}" ] || fail "check reported 'system'/'path:' pseudo-versions as pending"
pass "asdf-provision check ignores 'system'/'path:' pseudo-versions"

OWNERSHIP_HOME="${TEST_DIR}/ownership-home"
READONLY_MOUNT="${OWNERSHIP_HOME}/reference [*]\docs"
WRITABLE_MOUNT="${OWNERSHIP_HOME}/writable project"
SIBLING_DIR="${OWNERSHIP_HOME}/reference x\docs"
mkdir -p "${READONLY_MOUNT}/nested" "${WRITABLE_MOUNT}/nested" "${SIBLING_DIR}" "${OWNERSHIP_HOME}/.asdf"
touch "${READONLY_MOUNT}/nested/file" "${WRITABLE_MOUNT}/nested/file" "${SIBLING_DIR}/file" "${OWNERSHIP_HOME}/.asdf/tool"
ln -s "${READONLY_MOUNT}/nested/file" "${OWNERSHIP_HOME}/reference-link"
ln -s "${TEST_DIR}/missing-target" "${OWNERSHIP_HOME}/dangling-link"
MOUNTINFO="${TEST_DIR}/mountinfo"
: > "${MOUNTINFO}"
for target in "${OWNERSHIP_HOME}" "${READONLY_MOUNT}" "${WRITABLE_MOUNT}"; do
    encoded_target="${target//\\/\\134}"
    encoded_target="${encoded_target// /\\040}"
    printf '1 0 0:1 / %s rw - ext4 /dev/test rw\n' "${encoded_target}" >> "${MOUNTINFO}"
done
CHOWN_CAPTURE="${TEST_DIR}/chown-calls"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'no_follow=0' \
    'if [ "${1:-}" = "-h" ]; then no_follow=1; shift; fi' \
    'shift' \
    'printf "%s\n" "$@" >> "${CHOWN_CAPTURE}"' \
    'for path in "$@"; do' \
    '  if [ -L "${path}" ] && [ "${no_follow}" -eq 0 ]; then exit 1; fi' \
    '  case "${path}" in' \
    '    "${READONLY_MOUNT}"|"${READONLY_MOUNT}/"*) exit 1 ;;' \
    '  esac' \
    'done' > "${FAKE_BIN}/chown"
chmod 755 "${FAKE_BIN}/chown"
env PATH="${FAKE_BIN}:${PATH}" CHOWN_CAPTURE="${CHOWN_CAPTURE}" READONLY_MOUNT="${READONLY_MOUNT}" \
    bash "${ROOT_DIR}/lib/align-home-ownership.sh" "${OWNERSHIP_HOME}" 1000 1000 "${MOUNTINFO}" ||
    fail "ownership alignment attempted to chown a read-only mount"
grep -Fxq "${OWNERSHIP_HOME}/.asdf/tool" "${CHOWN_CAPTURE}" ||
    fail "ownership alignment skipped persistent tools"
grep -Fxq "${SIBLING_DIR}/file" "${CHOWN_CAPTURE}" ||
    fail "mount path glob characters matched an unrelated directory"
grep -Fxq "${OWNERSHIP_HOME}/reference-link" "${CHOWN_CAPTURE}" ||
    fail "ownership alignment skipped a symlink to a mounted file"
grep -Fxq "${OWNERSHIP_HOME}/dangling-link" "${CHOWN_CAPTURE}" ||
    fail "ownership alignment skipped a dangling symlink"
! grep -Fq "${WRITABLE_MOUNT}" "${CHOWN_CAPTURE}" ||
    fail "ownership alignment touched a writable project mount"
! grep -Fq "${READONLY_MOUNT}" "${CHOWN_CAPTURE}" ||
    fail "ownership alignment touched a read-only project mount"
rm -f "${FAKE_BIN}/chown"
bash "${ROOT_DIR}/lib/align-home-ownership.sh" "${OWNERSHIP_HOME}" "$(id -u)" "$(id -g)" "${MOUNTINFO}" ||
    fail "ownership alignment failed on symlinks"
pass "ownership alignment prunes nested mounts and does not follow symlinks"

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
grep -q '^rm -f id-copilot-container-' "${ENGINE_CALLS}" ||
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
grep -q '^logs -f id-copilot-container-' "${ENGINE_CALLS}" ||
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
