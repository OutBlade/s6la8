#!/usr/bin/env bash
# Run a command inside the s6la8 development container with the repo mounted
# at /work.  Usage: ./dev.sh make sim
set -euo pipefail

# Git Bash rewrites /work into a Windows path unless told not to.
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if pwd -W >/dev/null 2>&1; then
    here="$(cd "$here" && pwd -W)"
fi

image="${S6LA8_IMAGE:-s6la8-dev}"
if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" "$here/docker"
fi

exec docker run --rm -v "$here:/work" -w /work "$image" "$@"
