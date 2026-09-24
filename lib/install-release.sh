#!/usr/bin/env bash
# Shared installer for pinned, checksum-verified upstream release tarballs.
# Used by the Containerfile to install every tool that has no (or no
# sufficiently pinnable) apt package: hunk, copilot, mado, node, go, maven,
# temurin (openjdk) and tofu. Centralizes download + checksum verification +
# extraction so each tool's Containerfile RUN block only needs to supply the
# handful of values that actually differ between tools.
#
# Modes:
#   bin    single binary extracted to /usr/local/bin/<name>
#   merge  tarball's top-level directory contents merged into --dest
#          (default /usr/local), e.g. Node.js
#   tree   tarball extracted as a self-contained directory at --dest, with
#          optional --link entries symlinked into /usr/local/bin, e.g. Go,
#          Maven, Temurin OpenJDK
#
# Checksum styles:
#   sumfile  --checksum-url points to a multi- or single-entry
#            "<hash>  <filename>" file; the matching line is grepped out
#   rawhash  --checksum-url points to a file containing only the hash
#   jsonapi  --checksum-url points to a JSON document; --jq-filter selects
#            the hash field (used by Go, whose only official per-release
#            checksum source is the go.dev/dl JSON API)
set -euo pipefail

name='' mode='' url='' checksum_url='' checksum_style=sumfile hash_algo=sha256
strip_components=0 dest=/usr/local jq_filter=''
links=()

while [ $# -gt 0 ]; do
    case "$1" in
        --name) name=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --url) url=$2; shift 2 ;;
        --checksum-url) checksum_url=$2; shift 2 ;;
        --checksum-style) checksum_style=$2; shift 2 ;;
        --hash-algo) hash_algo=$2; shift 2 ;;
        --strip-components) strip_components=$2; shift 2 ;;
        --dest) dest=$2; shift 2 ;;
        --jq-filter) jq_filter=$2; shift 2 ;;
        --link) links+=("$2"); shift 2 ;;
        *) echo "install-release.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

for required in name mode url checksum_url; do
    if [ -z "${!required}" ]; then
        echo "install-release.sh: --${required} is required" >&2
        exit 1
    fi
done

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

archive="${workdir}/$(basename "${url}")"
curl -fsSL -o "${archive}" "${url}"

case "${checksum_style}" in
    sumfile)
        curl -fsSL "${checksum_url}" \
            | grep " $(basename "${archive}")\$" \
            | (cd "${workdir}" && "${hash_algo}sum" -c -)
        ;;
    rawhash)
        hash="$(curl -fsSL "${checksum_url}" | tr -d '[:space:]')"
        echo "${hash}  $(basename "${archive}")" \
            | (cd "${workdir}" && "${hash_algo}sum" -c -)
        ;;
    jsonapi)
        hash="$(curl -fsSL "${checksum_url}" | jq -r "${jq_filter}")"
        echo "${hash}  $(basename "${archive}")" \
            | (cd "${workdir}" && "${hash_algo}sum" -c -)
        ;;
    *)
        echo "install-release.sh: unknown --checksum-style: ${checksum_style}" >&2
        exit 1
        ;;
esac

case "${mode}" in
    bin)
        tar -xf "${archive}" -C "${workdir}" --strip-components="${strip_components}"
        install -m 0755 "${workdir}/${name}" "/usr/local/bin/${name}"
        ;;
    merge)
        mkdir -p "${dest}"
        tar -xf "${archive}" -C "${dest}" --strip-components="${strip_components}"
        ;;
    tree)
        rm -rf "${dest}"
        mkdir -p "${dest}"
        tar -xf "${archive}" -C "${dest}" --strip-components="${strip_components}"
        for link in "${links[@]}"; do
            src="${link%%=*}"
            target="${link#*=}"
            ln -sf "${dest}/${src}" "/usr/local/bin/${target}"
        done
        ;;
    *)
        echo "install-release.sh: unknown --mode: ${mode}" >&2
        exit 1
        ;;
esac
