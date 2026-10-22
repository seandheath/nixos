{ pkgs, upstream }:

# cclaude launcher with opt-in access to USB/UART devices, host SSH, and the YNAB MCP server.
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

  . ${./container-devices.sh}
  . ${./container-ynab.sh}

  allow_ssh=false
  _kept=()
  for _arg in "$@"; do
    if [[ "$_arg" == --allow-ssh ]]; then
      allow_ssh=true
    else
      _kept+=("$_arg")
    fi
  done
  set -- "''${_kept[@]}"

  container_command=()
  if $enable_ynab; then
    container_command=(claude --dangerously-skip-permissions --mcp-config ${ynabMcpConfig})
  fi

  if [[ ! -f "$token_file" ]]; then
    ${upstream.cclaude-setup}/bin/cclaude-setup
  fi

  # Rebuild on the latest base image; layer caching makes this cheap when nothing changed.
  ${upstream.cclaude-update}/bin/cclaude-update >/dev/null

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

  ${import ./container-ssh.nix { inherit pkgs; }}

  # Host SSH config and known hosts; IdentityFile entries resolve to agent keys via their .pub files.
  if $allow_ssh; then
    if [[ ! -S "''${SSH_AUTH_SOCK:-}" ]]; then
      echo "cclaude: --allow-ssh requested, but no ssh-agent socket is available" >&2
      exit 1
    fi
    sshagent_args+=(-v "$(readlink -f "$HOME/.ssh/config"):/etc/ssh/ssh_config:ro"
      -v "$HOME/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro")
    for pub in "$HOME"/.ssh/*.pub; do
      sshagent_args+=(-v "$(readlink -f "$pub"):/home/claude/.ssh/''${pub##*/}:ro")
    done
  fi

  # Claude Code lives in the home volume, not the image, so update it there before starting.
  ${podman} run --rm \
    --userns=keep-id \
    --cap-drop=ALL \
    --security-opt no-new-privileges:true \
    --security-opt label=disable \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 \
    -v cclaude-home:/home/claude:rw,U \
    -e HOME=/home/claude \
    "$image" claude update >/dev/null

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
    "''${device_args[@]}" \
    "''${ynab_args[@]}" \
    -v /nix/store:/nix/store:ro \
    -v ${pkgs.mmdc}/bin/mmdc:/usr/local/bin/mmdc:ro \
    -v /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
    -v /nix/var/nix/profiles:/nix/var/nix/profiles:ro \
    -e CLAUDE_CODE_OAUTH_TOKEN="''${token}" \
    -e HOME=/home/claude \
    -e NIX_REMOTE=daemon \
    -e CLAUDE_CODE_PLUGIN_DIRS=${./claude-usage-limits} \
    -e $'NIX_CONFIG=max-jobs = 6\ncores = 4' \
    -e TERM="''${TERM:-xterm-256color}" \
    -e COLORTERM="''${COLORTERM:-truecolor}" \
    "''${gitconfig_args[@]}" \
    "''${claudemd_args[@]}" \
    "''${sshagent_args[@]}" \
    -w "/''${project_name}" \
    "$image" \
    "''${container_command[@]}" "$@"
''
