{ config, pkgs, inputs, lib, osConfig, ... }:
let
  # Pi coding agent (pi.dev) and its sops-templated Open WebUI config are
  # workstation-only. hydrogen (server) has no user-level age key at
  # ~/.config/sops/age/keys.txt, so the home sops activation for the openwebui
  # secrets fails there — and we don't want Pi on the server anyway. Gate on the
  # host so hydrogen's home config needs no user secrets. osConfig is the NixOS
  # config (home-manager runs as a NixOS module here).
  enablePi = osConfig.networking.hostName != "hydrogen";
in
{
  imports = [
    ./bash.nix
    ./kitty.nix
    ./git.nix
    ./go.nix
    ./neovim.nix
    ./vscode.nix
    ./monitors.nix
    inputs.sops-nix.homeManagerModules.sops
  ];

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
    secrets."openwebui-url" = { };
    secrets."openwebui-model" = { };
    secrets."openwebui-api-key" = { };
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
            contextWindow = 32768; # adjust to the served model
            maxTokens = 8192; # adjust to the served model
            input = [ "text" ];
          }];
        };
      };
    };
  };

  home.packages = [
    inputs.cclaude.packages.x86_64-linux.default
    inputs.cclaude.packages.x86_64-linux.cclaude-build
    inputs.cclaude.packages.x86_64-linux.cclaude-update
    inputs.cclaude.packages.x86_64-linux.cclaude-shell
    inputs.cclaude.packages.x86_64-linux.cclaude-setup
  ] ++ lib.optionals enablePi [
    inputs.pi-flake.packages.x86_64-linux.default
  ];
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
