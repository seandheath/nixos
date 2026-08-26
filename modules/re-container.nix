{ pkgs, ... }:

# `cqwen` and `copencode`: the RE agents in a rootless Podman sandbox rather than directly
# on the host. Both are driven by a remote model and handed a shell tool, so uncontained
# they reach SSH keys, GPG and this config. Modelled on the cclaude flake, whose security
# flags are the known-good reference. The host `qwen`/`opencode` stay as a fallback.
#
# WHAT THIS DOES NOT PROTECT: the Ghidra database. ReVa's write tools act on the live
# program on the HOST, through the MCP connection this deliberately punches through the
# network namespace. Measured, not assumed -- all 88 ReVa tools are auto-approved in both
# clients, including all 14 write tools; that is a different code path from the shell tool,
# whose narrow python3 allow-rules do gate it. Deliberate: unrestricted ReVa is the point of
# the tool. Both clients can gate it if that is revisited -- qwen-code builds rule names as
# mcp__<server>__<tool>, and OpenCode's schema takes arbitrary keys named reva_<tool>.
#
# The remaining control is procedural, which is why prompts/re-agent.md leads with it: open
# a COPY of the project, not the primary one. "It's in a container" says nothing about the
# database on the other end of the socket.
#
# `--network=pasta:-T,8080` forwards the container's localhost:8080 to the host's, which is
# the only way to reach ReVa -- it binds loopback, and podman's host.containers.internal is
# pasta's gateway, where 8080 is unreachable. Measured from inside: host 8080 reachable,
# 8384 and 631 blocked, outbound 443 and DNS fine. `--network=host` also works but exposes
# every host-local service; rejected.
#
# Needs rootless podman, set up in modules/virtualisation.nix.
let
  image = pkgs.re-container;
  imageName = "localhost/re-agents:latest";
  podman = "${pkgs.podman}/bin/podman";

  # The image is already a store path, so this is just an import.
  cqwen-build = pkgs.writeShellScriptBin "cqwen-build" ''
    set -euo pipefail
    exec ${podman} load -i ${image}
  '';

  # Shared launcher. $1 is the in-container command; the rest are the user's args.
  #
  # Mounts: cwd -> /<basename> read-write, the only writable path touching the host. qwen's
  # settings.json and QWEN.md go to /run/config/qwen read-only because the entrypoint has to
  # copy them into $HOME (qwen-code rewrites settings.json on startup); opencode.json goes
  # straight into $HOME since OpenCode only reads it. re-instructions.md is mounted at its
  # HOST absolute path -- opencode.json bakes that path in and resolves it literally.
  #
  # Secrets go in as environment variables, never as a mounted file, so nothing secret is
  # written into the persistent home volume.
  mkLauncher = name: extraArgs: cmd: pkgs.writeShellScriptBin name ''
    set -euo pipefail

    if ! ${podman} image exists ${imageName} 2>/dev/null; then
      printf '%s: image not found, loading...\n' "${name}" >&2
      ${cqwen-build}/bin/cqwen-build >&2
    fi

    project_dir="$(pwd)"
    # Podman container names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*, and the basename is also
    # the in-container mount point, so map anything outside that set to '-'. Same treatment
    # as cclaude's, including keeping \n so basename's trailing newline survives.
    project_name="$(basename "$project_dir" | tr -c 'a-zA-Z0-9_.\n-' '-')"

    # Host config paths. These are all symlinks — into the nix store for the home-manager
    # files, into the sops tmpfs for the rendered secrets — and podman needs the resolved
    # target, not the link.
    config_args=()
    qwen_settings="$(readlink -f "$HOME/.qwen/re-settings.json" 2>/dev/null || true)"
    qwen_context="$(readlink -f "$HOME/.qwen/QWEN.md" 2>/dev/null || true)"
    oc_config="$(readlink -f "$HOME/.config/opencode/opencode-re.json" 2>/dev/null || true)"
    oc_prompt="$(readlink -f "$HOME/.config/opencode/re-instructions.md" 2>/dev/null || true)"
    oc_datasheet_skill_file="$(readlink -f "$HOME/.config/opencode/skills/datasheet-reference/SKILL.md" 2>/dev/null || true)"
    oc_datasheet_skill=""
    [[ -f "$oc_datasheet_skill_file" ]] && oc_datasheet_skill="$(dirname "$oc_datasheet_skill_file")"

    [[ -f "$qwen_settings" ]] && config_args+=(-v "$qwen_settings:/run/config/qwen/settings.json:ro")
    [[ -f "$qwen_context"  ]] && config_args+=(-v "$qwen_context:/run/config/qwen/QWEN.md:ro")
    [[ -f "$oc_config"     ]] && config_args+=(-v "$oc_config:/home/re/.config/opencode/opencode.json:ro")
    [[ -f "$oc_prompt"     ]] && config_args+=(-v "$oc_prompt:$HOME/.config/opencode/re-instructions.md:ro")
    [[ -d "$oc_datasheet_skill" ]] && config_args+=(-v "$oc_datasheet_skill:/home/re/.config/opencode/skills/datasheet-reference:ro")

    # Endpoint secrets, sourced from the sops-rendered .env and passed through as env vars.
    env_args=()
    if [[ -f "$HOME/.qwen/.env" ]]; then
      set -a; . "$HOME/.qwen/.env"; set +a
      env_args=(-e OPENWEBUI_URL -e OPENWEBUI_MODEL -e OPENWEBUI_API_KEY)
    fi

    exec ${podman} run -it --rm \
      --name "${name}-''${project_name}" \
      \
      --userns=keep-id \
      \
      --cap-drop=ALL \
      --security-opt no-new-privileges:true \
      --security-opt label=disable \
      \
      --read-only \
      --tmpfs /tmp:rw,nosuid,nodev,size=2g,mode=1777 \
      -v re-agents-home:/home/re:rw,U \
      \
      -v "''${project_dir}:/''${project_name}:rw" \
      \
      --network=pasta:-T,8080 \
      \
      -e HOME=/home/re \
      -e TERM="''${TERM:-xterm-256color}" \
      -e COLORTERM="''${COLORTERM:-truecolor}" \
      \
      "''${config_args[@]}" \
      "''${env_args[@]}" \
      ${extraArgs} \
      \
      -w "/''${project_name}" \
      ${imageName} \
      ${cmd} "$@"
  '';

  # qwen-code's install is RE-only (its ~/.qwen carries ReVa and the RE context file), so
  # there is no agent flag to pass. OpenCode is a general coding tool whose RE behaviour
  # lives in a named agent, hence --agent re.
  cqwen = mkLauncher "cqwen" "" "qwen";
  copencode = mkLauncher "copencode" "" "opencode --agent re";
  cqwen-shell = mkLauncher "cqwen-shell" "" "bash";
in
{
  environment.systemPackages = [ cqwen copencode cqwen-shell cqwen-build ];
}
