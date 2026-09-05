{ pkgs, upstream }:

# cclaude launcher with opt-in access to USB/UART devices and the YNAB MCP server.
let
  podman = "${pkgs.podman}/bin/podman";
  image = "localhost/cclaude:latest";
  tokenFile = "\${HOME}/.config/cclaude/token";
  ynabMcpConfig = pkgs.writeText "cclaude-ynab-mcp.json" (builtins.toJSON {
    mcpServers.ynab.command = "${pkgs.ynab-mcp-server}/bin/ynab-mcp-server";
  });
in
pkgs.writeShellScriptBin "cclaude" ''
  set -euo pipefail

  token_file="${tokenFile}"
  image="${image}"

  allow_usb=false
  allow_uart=false
  enable_ynab=false
  forwarded_args=()
  for arg in "$@"; do
    if [[ "$arg" == --allow-usb ]]; then
      allow_usb=true
    elif [[ "$arg" == --allow-uart ]]; then
      allow_uart=true
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
      printf '%s\n' 'cclaude: --allow-usb requested, but /dev/bus/usb is unavailable' >&2
      exit 1
    fi
    # Mount the bus directory so devices that reconnect or re-enumerate remain visible.
    # keep-groups preserves access granted through host udev groups as well as ACLs.
    usb_args=(-v /dev/bus/usb:/dev/bus/usb:rw)
  fi

  uart_args=()
  if $allow_uart; then
    for device in /dev/ttyACM* /dev/ttyUSB*; do
      [[ -c "$device" ]] || continue
      uart_args+=(--device "$device:$device:rw")
    done
  fi

  device_group_args=()
  if $allow_usb || $allow_uart; then
    device_group_args=(--group-add=keep-groups)
  fi

  ynab_args=()
  container_command=()
  if $enable_ynab; then
    if [[ ! -s /run/secrets/ynab-api-token ]]; then
      printf '%s\n' 'cclaude: --ynab requested, but /run/secrets/ynab-api-token is unavailable or empty' >&2
      exit 1
    fi
    ynab_args=(-v /run/secrets/ynab-api-token:/run/secrets/ynab-api-token:ro)
    container_command=(claude --dangerously-skip-permissions --mcp-config ${ynabMcpConfig})
  fi

  if [[ ! -f "$token_file" ]]; then
    ${upstream.cclaude-setup}/bin/cclaude-setup
  fi

  if ! ${podman} image exists "$image" 2>/dev/null; then
    printf 'cclaude: image not found, building...\n' >&2
    ${upstream.cclaude-build}/bin/cclaude-build
  fi

  if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
    cat >&2 <<EOF
  cclaude: nix daemon socket not found at /nix/var/nix/daemon-socket/socket
    Ensure your NixOS config has:
      nix.enable = true;
      nix.settings.experimental-features = [ "nix-command" "flakes" ];
  EOF
    exit 1
  fi

  project_dir="$(pwd)"
  project_name="$(basename "$project_dir" | tr -c 'a-zA-Z0-9_.\n-' '-')"
  token="$(< "$token_file")"

  gitconfig_args=()
  if [[ -f "''${HOME}/.gitconfig" ]]; then
    gitconfig_args=(-v "''${HOME}/.gitconfig:/run/gitconfig:ro" -e GIT_CONFIG_GLOBAL=/run/gitconfig)
  elif [[ -f "''${HOME}/.config/git/config" ]]; then
    gitconfig_args=(-v "''${HOME}/.config/git/config:/run/gitconfig:ro" -e GIT_CONFIG_GLOBAL=/run/gitconfig)
  fi

  claudemd_args=()
  if [[ -f "''${HOME}/.claude/CLAUDE.md" ]]; then
    claudemd_args=(-v "''${HOME}/.claude/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro")
  fi

  sshagent_args=()
  if [[ -n "''${SSH_AUTH_SOCK:-}" ]]; then
    sshagent_args=(-v "''${SSH_AUTH_SOCK}:/run/ssh-agent.sock:ro" -e SSH_AUTH_SOCK=/run/ssh-agent.sock)
  fi

  exec ${podman} run -it --rm \
    --name "cclaude-''${project_name}" \
    --userns=keep-id \
    --cap-drop=ALL \
    --security-opt no-new-privileges:true \
    --security-opt label=disable \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 \
    -v cclaude-home:/home/claude:rw,U \
    -v "''${project_dir}:/''${project_name}:rw" \
    "''${usb_args[@]}" \
    "''${uart_args[@]}" \
    "''${device_group_args[@]}" \
    "''${ynab_args[@]}" \
    -v /nix/store:/nix/store:ro \
    -v /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
    -v /nix/var/nix/profiles:/nix/var/nix/profiles:ro \
    -e CLAUDE_CODE_OAUTH_TOKEN="''${token}" \
    -e HOME=/home/claude \
    -e NIX_REMOTE=daemon \
    -e TERM="''${TERM:-xterm-256color}" \
    -e COLORTERM="''${COLORTERM:-truecolor}" \
    "''${gitconfig_args[@]}" \
    "''${claudemd_args[@]}" \
    "''${sshagent_args[@]}" \
    -w "/''${project_name}" \
    "$image" \
    "''${container_command[@]}" "$@"
''
