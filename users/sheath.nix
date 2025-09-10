{ config, pkgs, inputs, ... }:
{
  imports = [
    ../home/bash.nix
    ../home/alacritty.nix
    ../home/git.nix
    ../home/go.nix
    ../home/neovim.nix
    ../home/vscode.nix
    ../home/hyprlock.nix
    ../home/hyprland-dock.nix
    inputs.sops-nix.homeManagerModules.sops
  ];
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/home/sheath/.config/sops/age/keys.txt";
  sops.secrets.gemini-api-key = {};
  sops.secrets.gitlab-token = {};
  sops.secrets.gitlab-username = {};
  programs.home-manager.enable = true;
  home.stateVersion = "25.05";
}
