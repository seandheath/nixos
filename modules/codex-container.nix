{ pkgs, ... }:

# `ccodex`: Codex with --yolo inside a rootless Podman boundary. The agent can write the
# current project and its own named home volume, but cannot see the host home, Codex config,
# credentials, SSH/GPG agents, or other working trees. Network access is intentionally left
# available for model calls and dependency downloads, without forwarding host-local ports.
let
  image = pkgs.codex-container;
  runtime = image.runtime;
  imageName = "localhost/ccodex:latest";
  podman = "${pkgs.podman}/bin/podman";

  ccodex-build = pkgs.writeShellScriptBin "ccodex-build" ''
    set -euo pipefail
    exec ${podman} load -i ${image}
  '';

  ccodex = pkgs.writeShellScriptBin "ccodex" ''
    set -euo pipefail

    # Keep the commands hidden by the host /nix/store mount alive across garbage collection:
    # ${runtime}

    if ! ${podman} image exists ${imageName} 2>/dev/null; then
      printf 'ccodex: image not found, loading...\n' >&2
      ${ccodex-build}/bin/ccodex-build >&2
    fi

    if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
      printf '%s\n' 'ccodex: Nix daemon socket not found' >&2
      exit 1
    fi

    project_dir="$(pwd)"
    project_name="$(basename "$project_dir" | tr -c 'a-zA-Z0-9_.\n-' '-')"

    # Author identity only. Authentication helpers, SSH agents and the host Codex home stay
    # outside the container; `codex login --device-auth` stores a separate login in the volume.
    gitconfig_args=()
    if [[ -f "$HOME/.gitconfig" ]]; then
      gitconfig_args=(-v "$HOME/.gitconfig:/run/gitconfig:ro" -e GIT_CONFIG_GLOBAL=/run/gitconfig)
    elif [[ -f "$HOME/.config/git/config" ]]; then
      gitconfig_args=(-v "$HOME/.config/git/config:/run/gitconfig:ro" -e GIT_CONFIG_GLOBAL=/run/gitconfig)
    fi

    exec ${podman} run -it --rm \
      --name "ccodex-''${project_name}" \
      --userns=keep-id \
      --cap-drop=ALL \
      --security-opt no-new-privileges:true \
      --security-opt label=disable \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 \
      -v ccodex-home:/home/codex:rw,U \
      -v "''${project_dir}:/''${project_name}:rw" \
      -v /nix/store:/nix/store:ro \
      -v /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
      -v /nix/var/nix/profiles:/nix/var/nix/profiles:ro \
      --network=pasta \
      -e HOME=/home/codex \
      -e USER=codex \
      -e NIX_REMOTE=daemon \
      -e TERM="''${TERM:-xterm-256color}" \
      -e COLORTERM="''${COLORTERM:-truecolor}" \
      "''${gitconfig_args[@]}" \
      -w "/''${project_name}" \
      ${imageName} \
      /bin/codex --yolo "$@"
  '';
in
{
  # Referencing runtime is deliberate: the image archive itself has no Nix references, and
  # its /nix/store is hidden by the host store mount when the container starts.
  environment.systemPackages = [
    ccodex
    ccodex-build
  ];
}
