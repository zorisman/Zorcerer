#!/usr/bin/env bash
# Launch the Zorcerer development container.
#
# Mounts:
#   scripts/agent-workspace/opencode.json
#       -> /home/dev/.config/opencode/opencode.json (read-only)
#   repository root
#       -> /home/dev/Repository/Zorcerer
#
# The container starts OpenCode in the mounted repository. Extra arguments are
# forwarded to OpenCode; pass `bash` explicitly to start a shell instead.
#
# Environment:
#   ZORCERER_IMAGE  Container image name (default: zorcerer-dev)
set -euo pipefail

# Resolve paths relative to this script so the launcher works from any CWD.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

config_file="${script_dir}/opencode.json"
image="${ZORCERER_IMAGE:-zorcerer-dev}"
container_home="/home/dev"
container_repo="${container_home}/Repository/Zorcerer"

if ! command -v docker >/dev/null 2>&1; then
    echo "error: docker is not installed or not on PATH" >&2
    exit 1
fi

if [[ ! -f "${config_file}" ]]; then
    echo "error: OpenCode config not found: ${config_file}" >&2
    exit 1
fi

if [[ ! -d "${repo_root}" ]]; then
    echo "error: repository root not found: ${repo_root}" >&2
    exit 1
fi

# Default to the OpenCode TUI; any explicit arguments replace this command.
if (( $# == 0 )); then
    set -- opencode
fi

exec docker run --rm -it \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    -v "${config_file}:${container_home}/.config/opencode/opencode.json:ro" \
    -v "${repo_root}:${container_repo}" \
    -w "${container_repo}" \
    "${image}" "$@"
