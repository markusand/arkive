#!/usr/bin/env bash
set -Eeuo pipefail

# Set this once when publishing the repository on GitHub.
readonly REPOSITORY_SLUG='markusand/arkive'

if [[ -f "$(dirname -- "${BASH_SOURCE[0]}")/setup/install.sh" ]]; then
    REPOSITORY_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    exec bash "$REPOSITORY_ROOT/setup/install.sh" "$@"
fi

[[ $EUID -eq 0 ]] || { echo 'Run with sudo: curl ... | sudo bash' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo 'curl is required to download Arkive.' >&2; exit 1; }

TEMP_ROOT=$(mktemp -d /tmp/arkive-bootstrap.XXXXXX)
trap 'rm -rf "$TEMP_ROOT"' EXIT
ARCHIVE="$TEMP_ROOT/arkive.tar.gz"

curl -fL --retry 3 --retry-delay 2 \
    "https://github.com/${REPOSITORY_SLUG}/archive/refs/heads/main.tar.gz" \
    -o "$ARCHIVE"
mkdir "$TEMP_ROOT/source"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$TEMP_ROOT/source"
bash "$TEMP_ROOT/source/setup/install.sh" "$@"
