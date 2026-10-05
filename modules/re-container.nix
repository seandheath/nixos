{ pkgs, ... }:

# General-purpose agents in rootless Podman. --reva adds the RE config and forwards
# only host port 8080. ReVa writes still act on the host Ghidra database: open a copy.
let
  image = pkgs.re-container;
  imageName = "${image.imageName}:${image.imageTag}";
  podman = "${pkgs.podman}/bin/podman";
  cqwen-build = pkgs.writeShellScriptBin "cqwen-build" ''
    set -euo pipefail
    exec ${podman} load -i ${image}
  '';

  mkLauncher = name: cmd: pkgs.writeShellScriptBin name ''
    set -euo pipefail
    . ${../packages/reva-flag.sh}
    . ${../packages/container-devices.sh}

    # Qwen's existing setup and its shell remain RE-only.
    if [[ '${cmd}' == qwen || '${cmd}' == bash ]]; then reva=true; fi
    config_args=()
    env_args=()
    network=pasta:-T,none
    if $reva; then network=pasta:-T,8080; fi

    # Resolve Home Manager / SOPS symlinks before mounting, without copying secrets.
    resolve_file() {
      local source
      source="$(readlink -f "$1")" || source=""
      if [[ ! -f "$source" ]]; then
        printf '%s: configuration missing: %s (apply home-manager first)\n' '${name}' "$1" >&2
        exit 1
      fi
      printf '%s\n' "$source"
    }
    mount_file() {
      local source
      source="$(resolve_file "$1")"
      config_args+=(-v "$source:$2:ro")
    }

    case '${cmd}' in
      opencode)
        oc_config=opencode-container.json
        if $reva; then oc_config=opencode-container-re.json; fi
        mount_file "$HOME/.config/opencode/$oc_config" /home/re/.config/opencode/opencode.json
        mount_file "$HOME/.config/opencode/AGENTS.md" /home/re/.config/opencode/AGENTS.md
        if $reva; then
          mount_file "$HOME/.config/opencode/re-instructions.md" "$HOME/.config/opencode/re-instructions.md"
          skill="$(resolve_file "$HOME/.config/opencode/skills/datasheet-reference/SKILL.md")"
          config_args+=(-v "$(dirname "$skill"):/home/re/.config/opencode/skills/datasheet-reference:ro")
        fi
        ;;
      qwen|bash)
        if [[ -f "$HOME/.qwen/re-settings.json" ]]; then
          mount_file "$HOME/.qwen/re-settings.json" /run/config/qwen/settings.json
          mount_file "$HOME/.qwen/QWEN.md" /run/config/qwen/QWEN.md
        fi
        if [[ -f "$HOME/.qwen/.env" ]]; then
          set -a; . "$HOME/.qwen/.env"; set +a
          env_args=(-e OPENWEBUI_URL -e OPENWEBUI_MODEL -e OPENWEBUI_API_KEY)
        fi
        ;;
    esac

    if ! ${podman} image exists ${imageName} 2>/dev/null; then
      printf '%s: image not found, loading...\n' '${name}' >&2
      ${cqwen-build}/bin/cqwen-build >&2
    fi
    project_dir="$(pwd)"
    project_name="$(basename "$project_dir" | tr -c 'a-zA-Z0-9_.\n-' '-')"

    exec ${podman} run -it --rm \
      --name "${name}-''${project_name}" \
      --userns=keep-id \
      --cap-drop=ALL \
      --security-opt no-new-privileges:true \
      --security-opt label=disable \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 \
      -v re-agents-home:/home/re:rw,U \
      -v "''${project_dir}:''${project_dir}:rw" \
      -v /nix/store:/nix/store:ro \
      -v /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
      -v /nix/var/nix/profiles:/nix/var/nix/profiles:ro \
      -v /run/current-system:/run/current-system:ro \
      --network="$network" \
      -e HOME=/home/re \
      -e PATH=/bin:/run/current-system/sw/bin \
      -e NIX_REMOTE=daemon \
      -e 'NIX_CONFIG=experimental-features = nix-command flakes' \
      -e TERM="''${TERM:-xterm-256color}" \
      -e COLORTERM="''${COLORTERM:-truecolor}" \
      "''${config_args[@]}" \
      "''${env_args[@]}" \
      "''${device_args[@]}" \
      -w "''${project_dir}" \
      ${imageName} \
      ${cmd} "$@"
  '';

  cqwen = mkLauncher "cqwen" "qwen";
  copencode = mkLauncher "copencode" "opencode";
  cqwen-shell = mkLauncher "cqwen-shell" "bash";
in {
  environment.systemPackages = [ cqwen copencode cqwen-shell cqwen-build image.runtime ];
}
