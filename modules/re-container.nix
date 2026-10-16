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

    # The shell remains RE-only.
    if [[ '${cmd}' == bash ]]; then reva=true; fi
    config_args=()
    network=pasta:-T,none
    if $reva; then network=pasta:-T,8080; fi
    sshagent_args=()
    ${pkgs.lib.optionalString (cmd == "opencode") (import ../packages/container-ssh.nix { inherit pkgs; })}

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

    command='${cmd}'
    case '${cmd}' in
      opencode)
        # Latest opencode from npm, patched for NixOS. The image's /nix/store copy only
        # changes on a system rebuild.
        oc_dir="$HOME/.local/share/copencode"
        oc_version="$(${pkgs.curl}/bin/curl -fsSL https://registry.npmjs.org/@opencode/cli-linux-x64/latest | ${pkgs.jq}/bin/jq -er .version)"
        if [[ "$(cat "$oc_dir/version" 2>/dev/null)" != "$oc_version" ]]; then
          printf '%s: installing opencode %s...\n' '${name}' "$oc_version" >&2
          oc_tmp="$(mktemp -d)"
          ${pkgs.curl}/bin/curl -fsSL "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-$oc_version.tgz" \
            | tar -xz -C "$oc_tmp"
          ${pkgs.patchelf}/bin/patchelf \
            --set-interpreter ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 \
            --set-rpath ${pkgs.glibc}/lib \
            "$oc_tmp/package/bin/opencode"
          mkdir -p "$oc_dir"
          mv -f "$oc_tmp/package/bin/opencode" "$oc_dir/opencode"
          rm -rf "$oc_tmp"
          printf '%s\n' "$oc_version" > "$oc_dir/version"
        fi
        config_args+=(-v "$oc_dir/opencode:/run/opencode:ro" -e OPENCODE_DISABLE_AUTOUPDATE=true)
        command=/run/opencode

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
      -e $'NIX_CONFIG=experimental-features = nix-command flakes\nmax-jobs = 6\ncores = 4' \
      -e TERM="''${TERM:-xterm-256color}" \
      -e COLORTERM="''${COLORTERM:-truecolor}" \
      "''${config_args[@]}" \
      "''${sshagent_args[@]}" \
      "''${device_args[@]}" \
      -w "''${project_dir}" \
      ${imageName} \
      "$command" "$@"
  '';

  copencode = mkLauncher "copencode" "opencode";
  cqwen-shell = mkLauncher "cqwen-shell" "bash";
in {
  environment.systemPackages = [ copencode cqwen-shell cqwen-build image.runtime ];
}
