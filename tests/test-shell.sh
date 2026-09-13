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
    local output
    if output="$("$@" 2>&1)"; then
        fail "expected command to fail: $*"
    fi
    printf '%s\n' "${output}" | grep -Fq -- "${expected}" ||
        fail "expected output to contain: ${expected}"
}

assert_output_contains "-m requires a value" "${LAUNCHER}" -m
pass "missing option values are rejected"

assert_output_contains "--engine must be podman or docker" \
    "${LAUNCHER}" --engine invalid -m "${TEST_DIR}"
pass "invalid engines are rejected"

PROJECT="${TEST_DIR}/project"
mkdir -p "${PROJECT}" "${TEST_DIR}/home/.copilot"
printf '%s\n' '[user]' > "${TEST_DIR}/home/.gitconfig"
printf '%s\n' '{}' > "${TEST_DIR}/home/.copilot/config.json"
printf '%s\n' 'instructions' > "${TEST_DIR}/home/.copilot/copilot-instructions.md"

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
    '  run)' \
    '    printf "%s\n" "$@" > "${CAPTURE}"' \
    '    exit 0' \
    '    ;;' \
    'esac' \
    'exit 1' > "${FAKE_BIN}/podman"
chmod 755 "${FAKE_BIN}/podman"

HOME="${TEST_DIR}/home" CAPTURE="${CAPTURE}" PATH="${FAKE_BIN}:${PATH}" \
    "${LAUNCHER}" -m "${PROJECT}" >/dev/null

home_volume_line="$(grep -nE ':/home/copilot$' "${CAPTURE}" | head -n1 | cut -d: -f1)"
config_line="$(grep -nFx "${TEST_DIR}/home/.copilot/config.json:/home/copilot/.copilot/config.json:ro" "${CAPTURE}" | cut -d: -f1)"
instructions_line="$(grep -nFx "${TEST_DIR}/home/.copilot/copilot-instructions.md:/home/copilot/.copilot/copilot-instructions.md:ro" "${CAPTURE}" | cut -d: -f1)"

[ -n "${home_volume_line}" ] || fail "state volume was not passed to the engine"
[ -n "${config_line}" ] || fail "read-only Copilot config mount was not passed"
[ -n "${instructions_line}" ] || fail "read-only instructions mount was not passed"
[ "${home_volume_line}" -lt "${config_line}" ] ||
    fail "state volume must precede the Copilot config mount"
[ "${home_volume_line}" -lt "${instructions_line}" ] ||
    fail "state volume must precede the instructions mount"
pass "state volume precedes nested read-only mounts"

assert_output_contains "HOST_UID must be a numeric user ID" \
    env HOST_UID=invalid bash "${ENTRYPOINT}"
pass "invalid runtime UID is rejected"

echo "All shell tests passed."
