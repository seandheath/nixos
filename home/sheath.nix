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
  sops.secrets.gemini-api-key = {};
  sops.secrets.gitlab-token = {};
  sops.secrets.gitlab-username = {};
  sops.templates."secrets.env" = {
    content = ''
      GEMINI_API_KEY=${config.sops.placeholder.gemini-api-key}
      GITLAB_TOKEN=${config.sops.placeholder.gitlab-token}
      GITLAB_USERNAME=${config.sops.placeholder.gitlab-username}
    '';
  };
  home.packages = [
    inputs.cclaude.packages.x86_64-linux.default
    inputs.cclaude.packages.x86_64-linux.cclaude-build
    inputs.cclaude.packages.x86_64-linux.cclaude-update
    inputs.cclaude.packages.x86_64-linux.cclaude-shell
    inputs.cclaude.packages.x86_64-linux.cclaude-setup
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
