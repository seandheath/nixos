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
  home.packages = [
    inputs.cclaude.packages.x86_64-linux.default
    inputs.cclaude.packages.x86_64-linux.cclaude-build
    inputs.cclaude.packages.x86_64-linux.cclaude-update
    inputs.cclaude.packages.x86_64-linux.cclaude-shell
    inputs.cclaude.packages.x86_64-linux.cclaude-setup
  ];
  programs.home-manager.enable = true;
  home.stateVersion = "25.05";
}
