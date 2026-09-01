{ config, pkgs, inputs, lib, osConfig, ... }:
let
  vllm = import ../modules/vllm-endpoint.nix;

  # Role, derived from the NixOS config. sheath's account exists on all six hosts, but only
  # sulfur is a machine he sits at -- hydrogen is a headless-ish server and the kids'
  # laptops carry this account purely for remote administration. Without this they each
  # built VSCodium, treesitter with every grammar, and a dock script hardcoded to three
  # specific monitor serials.
  workstation = osConfig.networking.hostName == "sulfur";
  # Pi coding agent (pi.dev) and its sops-templated Open WebUI config are
  # workstation-only. hydrogen (server) has no user-level age key at
  # ~/.config/sops/age/keys.txt, so the home sops activation for the openwebui
  # secrets fails there — and we don't want Pi on the server anyway. Gate on the
  # host so hydrogen's home config needs no user secrets. osConfig is the NixOS
  # config (home-manager runs as a NixOS module here).
  #
  # The family laptops are excluded for a different reason: they carry the FAMILY age
  # key, which by design cannot decrypt secrets/secrets.yaml (see .sops.yaml), so the
  # openwebui-* secrets below would fail activation there.
  enablePi = workstation;
  cclaude = inputs.cclaude.packages.x86_64-linux.default;
  porkbunMcp = "${pkgs.porkbun-domain-search-mcp}/bin/porkbun-domain-search-mcp";
in
{
  imports = [
    ./bash.nix
    ./git.nix
    ./neovim.nix
    inputs.sops-nix.homeManagerModules.sops
    inputs.nix-index-database.homeModules.nix-index
  ] ++ lib.optionals workstation [
    ./ghostty.nix
    ./ssh.nix
    ./vscode.nix
    ./monitors.nix
  ];

  programs.go.enable = true;

  # nix-index: `nix-locate <file>` finds which package provides a binary/file,
  # and hooks bash's command-not-found to suggest the package. comma (`,`)
  # runs an uninstalled program directly from the index. The file database is
  # the prebuilt one from the nix-index-database input (no local `nix-index`
  # run); it refreshes when that input is bumped (`nu`). Shared across all
  # hosts via commonModules.
  programs.nix-index.enable = true;
  programs.nix-index-database.comma.enable = true;

  # Pi's Open WebUI provider config is rendered at activation from sops so the
  # internal URL, model id and API key never land in the (public) flake or the
  # nix store. Pi reads ~/.pi/agent/models.json and supports $VAR interpolation
  # only for apiKey — not baseUrl/model id — so the whole file is templated
  # rather than using env vars. sops-install-secrets mkdir -p's the parent,
  # creating ~/.pi/agent/. Pi owns the rest of ~/.pi at runtime (sessions,
  # /login auth), so we install the package directly instead of pi-flake's HM
  # module (whose activation would clobber this models.json).
  # Workstation-only (see enablePi above).
  sops = lib.mkIf enablePi {
    defaultSopsFile = ../secrets/secrets.yaml;
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    secrets = lib.genAttrs vllm.secretNames (_: { });
    templates."pi-models.json" = {
      path = "${config.home.homeDirectory}/.pi/agent/models.json";
      content = builtins.toJSON {
        providers.openwebui = {
          baseUrl = config.sops.placeholder."openwebui-url";
          apiKey = config.sops.placeholder."openwebui-api-key";
          api = "openai-completions"; # Open WebUI speaks the OpenAI API
          models = [{
            id = config.sops.placeholder."openwebui-model";
            name = "Local (Open WebUI)";
            contextWindow = vllm.contextWindow;
            maxTokens = vllm.maxOutput;
            input = [ "text" ];
          }];
        };
      };
    };
  };

  home.packages = [
    cclaude
    inputs.cclaude.packages.x86_64-linux.cclaude-build
    inputs.cclaude.packages.x86_64-linux.cclaude-update
    inputs.cclaude.packages.x86_64-linux.cclaude-shell
    inputs.cclaude.packages.x86_64-linux.cclaude-setup
  ] ++ lib.optionals enablePi [
    inputs.pi-flake.packages.x86_64-linux.default
  ];

  # Both native clients own mutable user configuration, so register the declarative command
  # only when it differs. Their MCP processes load credentials from the SOPS-backed launcher.
  # Claude is installed by its upstream installer under ~/.local, not by the cclaude flake:
  # cclaude is a Podman wrapper with only bin/cclaude and an isolated config volume. Keep
  # the native registration optional so a fresh machine without that installer can still
  # activate Home Manager.
  home.activation.porkbunMcpClients = lib.mkIf workstation
    (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      porkbun_command=${lib.escapeShellArg porkbunMcp}

      codex_config="$(${pkgs.codex}/bin/codex mcp get porkbun 2>/dev/null || true)"
      if [[ "$codex_config" != *"$porkbun_command"* ]]; then
        run ${pkgs.codex}/bin/codex mcp remove porkbun >/dev/null 2>&1 || true
        run ${pkgs.codex}/bin/codex mcp add porkbun -- "$porkbun_command"
      fi

      claude_bin="$HOME/.local/bin/claude"
      if [[ -x "$claude_bin" ]]; then
        claude_config="$("$claude_bin" mcp get porkbun 2>/dev/null || true)"
        if [[ "$claude_config" != *"$porkbun_command"* ]]; then
          run "$claude_bin" mcp remove porkbun --scope user >/dev/null 2>&1 || true
          run "$claude_bin" mcp add --scope user porkbun -- "$porkbun_command"
        fi
      fi
    '');

  home.username = "sheath";
  home.homeDirectory = "/home/sheath";
  home.sessionPath = [
    "$HOME/go/bin/"
    "$HOME/.cargo/bin/"
    "$HOME/.local/bin/"
  ];
  programs.home-manager.enable = true;
  home.stateVersion = "25.05";
}
