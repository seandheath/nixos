{ config, pkgs, inputs, ... }:
{
  imports = [
    ./bash.nix
    ./kitty.nix
    ./git.nix
    ./go.nix
    ./neovim.nix
    ./monitors.nix
    inputs.sops-nix.homeManagerModules.sops
  ];
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/home/sheath/.config/sops/age/keys.txt";

  # Pi coding agent (pi.dev) — the Open WebUI provider config is rendered at
  # activation from sops so the internal URL, model id and API key never land
  # in the (public) flake or the nix store. Pi reads ~/.pi/agent/models.json and
  # supports $VAR interpolation only for apiKey — not baseUrl/model id — so the
  # whole file is templated rather than using env vars. sops-install-secrets
  # mkdir -p's the parent, creating ~/.pi/agent/. Pi owns the rest of ~/.pi at
  # runtime (sessions, /login auth), so we install the package directly instead
  # of pi-flake's HM module (whose activation would clobber this models.json).
  sops.secrets."openwebui-url" = { };
  sops.secrets."openwebui-model" = { };
  sops.secrets."openwebui-api-key" = { };
  sops.templates."pi-models.json" = {
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

  home.packages = [
    inputs.cclaude.packages.x86_64-linux.default
    inputs.cclaude.packages.x86_64-linux.cclaude-build
    inputs.cclaude.packages.x86_64-linux.cclaude-update
    inputs.cclaude.packages.x86_64-linux.cclaude-shell
    inputs.cclaude.packages.x86_64-linux.cclaude-setup
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
