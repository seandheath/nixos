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
  programs.home-manager.enable = true;
  home.stateVersion = "25.05";
}
