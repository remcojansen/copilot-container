#!/usr/bin/env bash
#
# copilot-container asdf provisioning helper
#
# Runs inside the container, invoked by the host launcher over its SSH
# session (never by users directly). Detects and installs a project's
# pinned tool versions from its .tool-versions file.
#
# Usage:
#   copilot-container-asdf-provision check-plan <project_dir>
#   copilot-container-asdf-provision install <project_dir> <pending_tools>
#
# `check-plan` prints one "<plugin> <version>" line per pinned tool whose
# plugin isn't added yet or whose version isn't installed yet (no output
# means everything is already satisfied), then exits 0.
# `install` adds missing plugins and installs only the versions in
# `pending_tools`, as returned by `check-plan`.

set -euo pipefail

export PATH="/home/copilot/.asdf/shims:/home/copilot/.asdf/bin:${PATH}"

mode="${1:?usage: copilot-container-asdf-provision <check|install> <project_dir>}"
project_dir="${2:?usage: copilot-container-asdf-provision <check|install> <project_dir>}"

cd "${project_dir}"

trim_field() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

version_status() {
    local plugin="$1" version="$2" output
    if output="$(asdf where -- "${plugin}" "${version}" 2>&1)"; then
        return 0
    fi
    # asdf uses the same exit status for missing versions and other errors.
    case "${output}" in
        "Version not installed") return 1 ;;
        "No such plugin: ${plugin}") return 2 ;;
        *)
            printf 'error: asdf could not check %q %q: %s\n' "${plugin}" "${version}" "${output}" >&2
            return 3
            ;;
    esac
}

require_explicit_version() {
    case "$2" in
        latest|latest:*)
            printf 'error: cannot install %q %q explicitly; pin a specific version\n' "$1" "$2" >&2
            return 1
            ;;
    esac
}

pending() {
    [ -f .tool-versions ] || return 0
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"
        IFS=' ' read -r -a fields <<< "${line}"
        [ "${#fields[@]}" -gt 1 ] || continue
        plugin="$(trim_field "${fields[0]}")"
        [ -n "${plugin}" ] || continue
        for field in "${fields[@]:1}"; do
            version="$(trim_field "${field}")"
            case "${version}" in ''|system|path:*) continue ;; esac
            status=0
            version_status "${plugin}" "${version}" || status=$?
            case "${status}" in 0) continue ;; 1|2) ;; *) return "${status}" ;; esac
            require_explicit_version "${plugin}" "${version}" || return 1
            printf '%s %s\n' "${plugin}" "${version}"
        done
    done < .tool-versions
}

case "${mode}" in
    check|check-plan)
        pending
        ;;
    install)
        approved_tools="${3:?missing approved tools}"
        while IFS=' ' read -r plugin version || [ -n "${plugin}${version}" ]; do
            if [ -z "${plugin}" ] || [ -z "${version}" ]; then
                continue
            fi
            require_explicit_version "${plugin}" "${version}"
            status=0
            version_status "${plugin}" "${version}" || status=$?
            case "${status}" in
                0) continue ;;
                1) ;;
                2) asdf plugin add -- "${plugin}" ;;
                *) exit "${status}" ;;
            esac
            asdf install -- "${plugin}" "${version}"
        done <<< "${approved_tools}"
        ;;
    *)
        echo "error: copilot-container-asdf-provision: unknown mode: ${mode}" >&2
        exit 2
        ;;
esac
