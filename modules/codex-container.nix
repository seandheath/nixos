{ pkgs, lib, ... }:

# `ccodex`: Codex with --yolo inside a rootless Podman boundary. The agent can write the
# current project, its own named home volume, the host Codex directory, and only the two
# Porkbun credential files required by its read-only MCP server. The rest of the host home,
# SSH/GPG agents, and other working trees remain hidden; network access stays available.
# `--allow-usb` and `--ynab` opt into peripheral and financial-data access respectively.
let
  image = pkgs.codex-container;
  runtime = image.runtime;
  imageName = "localhost/ccodex:${image.imageTag}";
  podman = "${pkgs.podman}/bin/podman";

  ccodex-build = pkgs.writeShellScriptBin "ccodex-build" ''
    set -euo pipefail
    exec ${podman} load -i ${image}
  '';

  ccodex = pkgs.writeShellScriptBin "ccodex" ''
    set -euo pipefail

    # Keep the commands hidden by the host /nix/store mount alive across garbage collection:
    # ${runtime}

    allow_usb=false
    enable_ynab=false
    forwarded_args=()
    for arg in "$@"; do
      if [[ "$arg" == --allow-usb ]]; then
        allow_usb=true
      elif [[ "$arg" == --ynab ]]; then
        enable_ynab=true
      else
        forwarded_args+=("$arg")
      fi
    done
    set -- "''${forwarded_args[@]}"

    usb_args=()
    if $allow_usb; then
      if [[ ! -d /dev/bus/usb ]]; then
        printf '%s\n' 'ccodex: --allow-usb requested, but /dev/bus/usb is unavailable' >&2
        exit 1
      fi
      # Mount the bus directory so devices that reconnect or re-enumerate remain visible.
      # keep-groups preserves access granted through host udev groups as well as ACLs.
      usb_args=(-v /dev/bus/usb:/dev/bus/usb:rw --group-add=keep-groups)
    fi

    ynab_args=()
    if $enable_ynab; then
      if [[ ! -s /run/secrets/ynab-api-token ]]; then
        printf '%s\n' 'ccodex: --ynab requested, but /run/secrets/ynab-api-token is unavailable or empty' >&2
        exit 1
      fi
      ynab_args=(-v /run/secrets/ynab-api-token:/run/secrets/ynab-api-token:ro)
    fi

    codex_home="$HOME/.codex"
    installed_codex="$codex_home/bin/codex"
    mkdir -p "$codex_home"

    # The shared Codex home keeps auth, settings, plugins, and conversations identical inside
    # and outside the container. Run explicit login commands on the host so their localhost
    # browser callback does not terminate inside the container's network namespace.
    if [[ "''${1:-}" == login ]]; then
      exec ${pkgs.codex}/bin/codex "$@"
    fi

    # Install the standalone CLI into the shared, writable Codex home. The Nix package remains
    # the reproducible fallback, while this lets `ccodex update` track upstream releases without
    # attempting to modify the immutable container image.
    if [[ "''${1:-}" == update ]]; then
      printf 'ccodex: installing the latest standalone Codex CLI...\n' >&2
      ${pkgs.curl}/bin/curl -fsSL https://chatgpt.com/codex/install.sh \
        | PATH="$codex_home/bin:$PATH" \
          CODEX_HOME="$codex_home" \
          CODEX_INSTALL_DIR="$codex_home/bin" \
          CODEX_NON_INTERACTIVE=1 \
          ${pkgs.bash}/bin/bash
      printf 'ccodex: now using ' >&2
      "$installed_codex" --version
      exit 0
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
    codex_command=/bin/codex
    if [[ -x "$installed_codex" ]]; then
      codex_command="$installed_codex"
    fi
    resume=false
    for arg in "$@"; do
      [[ "$arg" == resume ]] && resume=true
    done
    codex_args=(--yolo)
    if $enable_ynab; then
      codex_args+=(-c ${lib.escapeShellArg "mcp_servers.ynab.command=\"${pkgs.ynab-mcp-server}/bin/ynab-mcp-server\""})
    fi
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
      "''${usb_args[@]}" \
      "''${ynab_args[@]}" \
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
      "$codex_command" "''${codex_args[@]}" "$@")"

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
