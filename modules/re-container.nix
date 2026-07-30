{ pkgs, ... }:

# `cqwen` and `copencode`: the RE agents (modules/qwen-code.nix, modules/opencode.nix) run
# inside a rootless Podman sandbox instead of directly on the host.
#
# Both agents are driven by a remote model and handed a shell tool, so uncontained they can
# reach SSH keys, GPG, this NixOS config — everything in $HOME. This bounds them to the
# current directory. Modelled directly on cclaude (flake input github:seandheath/cclaude),
# which does the same for Claude Code; the security flags below are lifted from it because
# it is the known-good reference. The host `qwen`/`opencode` stay installed as a fallback.
#
# ── What this does NOT protect ────────────────────────────────────────────────────────
# **The Ghidra database, and nothing gates it.** ReVa's write tools act on the live program
# on the *host*, through the MCP connection this deliberately punches through the network
# namespace. Containment bounds the filesystem blast radius; it does not touch the analysis
# database.
#
# Measured, not assumed: **all 88 ReVa tools are auto-approved in both clients**, including
# all 14 write tools — set-comment, set-decompilation-comment, set-bookmark, create-label,
# create-function, set-function-prototype, rename-variables, apply-data-type,
# apply-structure, delete-structure, write-script and the diff-* session tools. Probed by
# having each agent attempt a real `delete-structure`; both dispatched it to the server with
# no confirmation. Note that this is a *different code path* from the shell tool: the narrow
# `python3 -c` allow-rules do gate bash, and MCP calls simply do not run through them.
#
# This is deliberate — Sean's call, 2026-07-30. Unrestricted ReVa is the point of the tool,
# and prompting on every retype would cost more than the risk. Both clients can gate it if
# that is ever revisited: qwen-code builds rule names as `mcp__<server>__<tool>` for
# `permissions.ask`/`deny`, and OpenCode's permission schema is `.catchall(PermissionRule)`
# so arbitrary keys work, with ReVa's tools named `reva_<tool>`.
#
# The only remaining control is procedural, and it is the reason prompts/re-agent.md leads
# its write-operations section with it: **open a copy of the project, not the primary one.**
# Containment makes that advice more load-bearing, not less — "it's in a container" says
# nothing about the database on the other end of the socket.
#
# ── Reaching ReVa ─────────────────────────────────────────────────────────────────────
# ReVa binds loopback only (`ss` shows [::ffff:127.0.0.1]:8080), so a container on default
# networking cannot see it: podman's host.containers.internal is pasta's gateway
# (169.254.1.2), where 8080 is unreachable, and pasta's --map-guest-addr did not help.
#
# `--network=pasta:-T,8080` is the fix. pasta's -T forwards the *container's* localhost:8080
# to the *host's* localhost:8080. Measured from inside such a container: host 8080 reachable,
# host 8384 (syncthing) and 631 (cups) blocked, outbound 443 and DNS to the vLLM endpoint
# fine. So the network namespace stays isolated with exactly one hole punched in it — and
# because the container's own localhost is what forwards, `mcpServers.reva.httpUrl =
# http://localhost:8080/mcp/message` works verbatim, with no container-specific config.
#
# `--network=host` also reaches ReVa but exposes every host-local service; rejected.
#
# Requires rootless podman and the subUid/subGid ranges for sheath, both already set up in
# modules/virtualisation.nix (imported by hosts/sulfur.nix and hosts/osmium.nix).
let
  image = import ../packages/re-container.nix { inherit pkgs; };
  imageName = "localhost/re-agents:latest";
  podman = "${pkgs.podman}/bin/podman";

  # Loads the nix-built image into podman's local storage. Equivalent to cclaude-build,
  # except there is nothing to fetch or compile at this point — the image is already a
  # store path, so this is just an import.
  cqwen-build = pkgs.writeShellScriptBin "cqwen-build" ''
    set -euo pipefail
    exec ${podman} load -i ${image}
  '';

  # Shared launcher. $1 is the in-container command to exec; the rest are the user's args.
  #
  # Mounts, and why each one is the shape it is:
  #   - cwd -> /<basename>, read-write. The only writable path that touches the host. Named
  #     after the directory the way cclaude does, so paths in agent output stay recognisable.
  #   - qwen's settings.json and QWEN.md -> /run/config/qwen, read-only; the entrypoint
  #     copies them into $HOME because qwen-code rewrites settings.json on startup.
  #   - opencode.json -> straight into $HOME, read-only: OpenCode only ever reads it.
  #   - re-instructions.md -> mounted at its *host* absolute path. opencode.json is rendered
  #     with `{file:${HOME}/.config/opencode/re-instructions.md}` baked in as an absolute
  #     path, and OpenCode resolves it literally, so the file has to appear there or config
  #     load fails outright. This is the one host-shaped path inside the container; it is a
  #     single read-only file we put there ourselves.
  #
  # Secrets go in as environment variables read from the sops-rendered ~/.qwen/.env, never
  # as a mounted file, so nothing secret is written into the persistent home volume.
  # qwen-code resolves settings.json's $OPENWEBUI_* placeholders from the process
  # environment exactly as it would from a .env file.
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
    qwen_settings="$(readlink -f "$HOME/.qwen/settings.json" 2>/dev/null || true)"
    qwen_context="$(readlink -f "$HOME/.qwen/QWEN.md" 2>/dev/null || true)"
    oc_config="$(readlink -f "$HOME/.config/opencode/opencode.json" 2>/dev/null || true)"
    oc_prompt="$(readlink -f "$HOME/.config/opencode/re-instructions.md" 2>/dev/null || true)"

    [[ -f "$qwen_settings" ]] && config_args+=(-v "$qwen_settings:/run/config/qwen/settings.json:ro")
    [[ -f "$qwen_context"  ]] && config_args+=(-v "$qwen_context:/run/config/qwen/QWEN.md:ro")
    [[ -f "$oc_config"     ]] && config_args+=(-v "$oc_config:/home/re/.config/opencode/opencode.json:ro")
    [[ -f "$oc_prompt"     ]] && config_args+=(-v "$oc_prompt:$HOME/.config/opencode/re-instructions.md:ro")

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
