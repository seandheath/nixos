#!/usr/bin/env bash
# Bootstrap the installer on a live ISO: `bash install.sh`.
#
# Everything the install actually does lives in installer/ (`nix run .#installer`); this
# only supplies what the ISO does not -- root, flakes, and the repo path.
# The previous shell implementation is in git history at 0a41c71.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The installer partitions disks and calls nixos-install, so it checks euid and refuses
# otherwise. Re-exec rather than making the operator remember `sudo -i` first.
if [[ ${EUID} -ne 0 ]]; then
    echo "install.sh: re-running as root"
    exec sudo -E bash "$0" "$@"
fi

[[ -f "${REPO}/flake.nix" ]] || {
    echo "install.sh: ${REPO} is not the configuration repository" >&2
    exit 1
}

# A clone supplies the tracked flake and installer source. Generated machine facts stay on
# the installed machine under /persist/nixos-install rather than being committed here.
[[ -d "${REPO}/.git" ]] || {
    echo "install.sh: ${REPO} is not a git checkout; clone it rather than copying." >&2
    exit 1
}

echo "install.sh: building the installer (later runs are cached)"

# The ISO ships with flakes off, and every nix call below needs them.
exec nix --extra-experimental-features "nix-command flakes" \
    run "${REPO}#installer" -- --repo "${REPO}" "$@"
