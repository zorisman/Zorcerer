#!/usr/bin/env bash
# Deploy the built Zorcerer shared library to a remote host for TF2 testing.
#
# Required environment variables:
#   ZORCERER_SSH_HOST   SSH host alias (configured in ~/.ssh/config)
#   ZORCERER_REMOTE_DIR Destination directory on the remote host
set -euo pipefail

# Resolve the repository root relative to this script so it works from any CWD.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

source_lib="${repo_root}/zig-out/lib/zorcerer.so"
source_plugins="${repo_root}/zig-out/lib/plugins"

if [[ -z "${ZORCERER_SSH_HOST:-}" ]]; then
    echo "error: ZORCERER_SSH_HOST is unset or empty" >&2
    exit 1
fi

if [[ -z "${ZORCERER_REMOTE_DIR:-}" ]]; then
    echo "error: ZORCERER_REMOTE_DIR is unset or empty" >&2
    exit 1
fi

if [[ ! -f "${source_lib}" ]]; then
    echo "error: source library not found: ${source_lib} (build the project first)" >&2
    exit 1
fi

if [[ ! -d "${source_plugins}" ]]; then
    echo "error: plugins directory not found: ${source_plugins} (build the project first)" >&2
    exit 1
fi

rsync --verbose --checksum "${source_lib}" "${ZORCERER_SSH_HOST}:${ZORCERER_REMOTE_DIR}/"
rsync --recursive --verbose --checksum "${source_plugins}/" "${ZORCERER_SSH_HOST}:${ZORCERER_REMOTE_DIR}/zorcerer/plugins/"
