#!/usr/bin/env bash
#
# copilot-container asdf provisioning helper
#
# Runs inside the container, invoked by the host launcher over its SSH
# session (never by users directly). Detects and installs a project's
# pinned tool versions from its .tool-versions file.
#
# Usage:
#   copilot-container-asdf-provision check <project_dir>
#   copilot-container-asdf-provision install <project_dir>
#
# `check` prints one "<plugin> <version>" line per pinned tool whose
# plugin isn't added yet or whose version isn't installed yet (no output
# means everything is already satisfied), then exits 0.
# `install` adds any missing plugins and installs the project's pinned
# versions.

set -euo pipefail

export PATH="/home/copilot/.asdf/shims:/home/copilot/.asdf/bin:${PATH}"

mode="${1:?usage: copilot-container-asdf-provision <check|install> <project_dir>}"
project_dir="${2:?usage: copilot-container-asdf-provision <check|install> <project_dir>}"

cd "${project_dir}"

if [ ! -f .tool-versions ]; then
    exit 0
fi

# First field is the plugin, second is its pinned version; blank/comment
# lines are skipped. Only the first version per line is checked (any
# further fallback versions on the same line are uncommon in practice and
# `asdf install` installs the whole file regardless of what's reported
# here).
pending() {
    while read -r plugin version _; do
        case "${plugin}" in ''|'#'*) continue ;; esac
        [ -z "${version}" ] && continue
        if ! asdf plugin list 2>/dev/null | grep -qx "${plugin}"; then
            echo "${plugin} ${version}"
            continue
        fi
        if ! asdf list "${plugin}" 2>/dev/null | tr -d ' ' | grep -qx "${version}"; then
            echo "${plugin} ${version}"
        fi
    done < .tool-versions
}

case "${mode}" in
    check)
        pending
        ;;
    install)
        while read -r plugin version; do
            asdf plugin list 2>/dev/null | grep -qx "${plugin}" || asdf plugin add "${plugin}"
        done < <(pending)
        asdf install
        ;;
    *)
        echo "error: copilot-container-asdf-provision: unknown mode: ${mode}" >&2
        exit 2
        ;;
esac
