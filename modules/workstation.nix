{ config, pkgs, ... }:
{

  imports = [
    ./gnome.nix
    ./kicad.nix
    ./syncthing.nix
  ];

  environment.systemPackages = with pkgs; [
    nextcloud-client
    teams-for-linux
    rtorrent
    nmap
    p7zip
    pkg-config
    unzip
    graphviz
    go
    rustup
    thefuck
    srm
    ripgrep
    gcc
    pandoc
    tectonic
    tmux
    nixpkgs-fmt
    libreoffice
    winetricks
    wineWowPackages.waylandFull
    protonup
    bibletime
    bitwarden
    vscodium
    keepassxc
    virt-manager
    brasero
    signal-desktop
    discord
    protonvpn-gui
    protonvpn-cli
    virt-manager
    appimage-run
  ];

  virtualisation = {
    oci-containers.backend = "podman";
    podman = {
      enable = true;
      dockerCompat = true;
    };
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };
}

