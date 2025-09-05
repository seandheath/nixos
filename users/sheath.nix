{ config, pkgs, ... }:
let
  home-manager = builtins.fetchTarball https://github.com/nix-community/home-manager/archive/release-25.05.tar.gz;
in {
  imports = [
    (import "${home-manager}/nixos")
  ];
  users.users.sheath = {
    isNormalUser = true;
    description = "sheath";
    extraGroups = [ "wheel" "networkmanager" "video" "libvirtd" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLhPOBx9dR2X3oYz5RS2eAGZA7YSeHPcnrQauHSmuk1"
    ];
  };
  home-manager.users.sheath = { pkgs, ... }: {
    imports = [
      ../home/bash.nix
      ../home/alacritty.nix
      ../home/git.nix
      ../home/go.nix
      ../home/neovim.nix
    ];
    programs.home-manager.enable = true;
    home.stateVersion = "25.05";
  };
}
