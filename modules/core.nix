# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:
let
	home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/master.tar.gz";
in {
  imports =
    [ # Include the results of the hardware scan.
      (import "${home-manager}/nixos")
    ];

  environment.systemPackages = with pkgs; [
    pv
    progress
    nix-index
    wormhole-william
    neovim
    git
    curl
    wget
    htop
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
  ];

  i18n.defaultLocale = "en_US.UTF-8";
  time.timeZone = "America/New_York";
  nixpkgs.config.allowUnfree = true;
}
