# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:{
  environment.systemPackages = with pkgs; [
    pv
    progress
    neovim
    nix-index
    wormhole-william
    git
    curl
    wget
    htop
    btop
    tree
    pciutils
    p7zip
    openssl
    pkg-config
    graphviz
    nmap
    unzip
    go
    rustup
    srm
    ripgrep
    gcc
    tmux
    nixpkgs-fmt
    niv
  ];
  nixpkgs.config.allowUnfree = true;
}
