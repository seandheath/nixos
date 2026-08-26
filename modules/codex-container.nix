{ pkgs, ... }:

# `ccodex`: Codex with --yolo inside a rootless Podman boundary. The agent can write the
# current project, its own named home volume, the host Codex directory, and only the two
# Porkbun credential files required by its read-only MCP server. The rest of the host home,
# SSH/GPG agents, and other working trees remain hidden; network access stays available.
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

    # The shared Codex home keeps auth, settings, plugins, and conversations identical inside
    # and outside the container. Run explicit login commands on the host so their localhost
    # browser callback does not terminate inside the container's network namespace.
    if [[ "''${1:-}" == login ]]; then
      exec ${pkgs.codex}/bin/codex "$@"
    fi

    if ! ${podman} image exists ${imageName} 2>/dev/null; then
      printf 'ccodex: image not found, loading...\n' >&2
      ${ccodex-build}/bin/ccodex-build >&2
    fi

    if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
      printf '%s\n' 'ccodex: Nix daemon socket not found' >&2
      exit 1
    fi

    project_dir="$(pwd)"
    codex_home="$HOME/.codex"

    mkdir -p "$codex_home"
    resume=false
    for arg in "$@"; do
      [[ "$arg" == resume ]] && resume=true
    done
    codex_args=(--yolo)
    if $resume; then
      # Resume in the project that ccodex was launched from; an explicit -C still takes
      # precedence if the user intentionally chooses another mounted path.
      codex_args+=(-c 'tui.resume_cwd="current"')
    fi

    # Author identity only. Authentication helpers and SSH agents stay outside the container.
    gitconfig_args=()
    if [[ -f "$HOME/.gitconfig" ]]; then
      gitconfig_args=(-v "$HOME/.gitconfig:/run/gitconfig:ro" -e GIT_CONFIG_GLOBAL=/run/gitconfig)
    elif [[ -f "$HOME/.config/git/config" ]]; then
      gitconfig_args=(-v "$HOME/.config/git/config:/run/gitconfig:ro" -e GIT_CONFIG_GLOBAL=/run/gitconfig)
    fi

    container_id=""
    cleanup() {
      local status=$?
      trap - EXIT INT HUP TERM
      if [[ -n "$container_id" ]]; then
        ${podman} stop --ignore --time 2 "$container_id" >/dev/null 2>&1 || true
        ${podman} rm --ignore "$container_id" >/dev/null 2>&1 || true
      fi
      exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 129' HUP
    trap 'exit 143' TERM

    container_id="$(${podman} create -it \
      --userns=keep-id \
      --cap-drop=ALL \
      --security-opt no-new-privileges:true \
      --security-opt label=disable \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 \
      -v ccodex-home:/home/codex:rw,U \
      -v "''${codex_home}:''${codex_home}:rw" \
      -v "''${project_dir}:''${project_dir}:rw" \
      -v /run/secrets/porkbun-api-key:/run/secrets/porkbun-api-key:ro \
      -v /run/secrets/porkbun-secret-api-key:/run/secrets/porkbun-secret-api-key:ro \
      -v /nix/store:/nix/store:ro \
      -v /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
      -v /nix/var/nix/profiles:/nix/var/nix/profiles:ro \
      --network=pasta \
      -e HOME=/home/codex \
      -e CODEX_HOME="''${codex_home}" \
      -e USER=codex \
      -e NIX_REMOTE=daemon \
      -e TERM="''${TERM:-xterm-256color}" \
      -e COLORTERM="''${COLORTERM:-truecolor}" \
      "''${gitconfig_args[@]}" \
      -w "''${project_dir}" \
      ${imageName} \
      /bin/codex "''${codex_args[@]}" "$@")"

    set +e
    ${podman} start -a -i --detach-keys=ctrl-c --sig-proxy=false "$container_id"
    status=$?
    set -e
    exit "$status"
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
