# Admin CLI tooling for hydrogen.
{ config, pkgs, lib, ... }:
{
  environment.systemPackages = with pkgs; [
    pv
    progress
    neovim
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
}
