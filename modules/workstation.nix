{ config, pkgs, ... }:
{

  imports = [
    ./gnome.nix
    ./syncthing.nix
  ];

  environment.systemPackages = with pkgs; [
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
    nvtop
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
    appflowy
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

