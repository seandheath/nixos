{ config, pkgs, inputs, ... }:
{
  imports = [
    ../home/bash.nix
    ../home/alacritty.nix
    ../home/git.nix
    ../home/go.nix
    ../home/neovim.nix
    inputs.sops-nix.homeManagerModules.sops
  ];
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/home/sheath/.config/sops/age/keys.txt";
  sops.secrets.gemini-api-key = {};
  programs.home-manager.enable = true;
  home.stateVersion = "25.05";
}
