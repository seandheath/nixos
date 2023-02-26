{ config, pkgs, lib, ... }:
{
  # Desktop Environment
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  services.udev.packages = with pkgs; [
    gnome.gnome-settings-daemon
  ];
  systemd.services.NetworkManager-wait-online.enable = false;
  services.printing.enable = true;
  services.printing.drivers = with pkgs; [
    gutenprint
    gutenprintBin
    brlaser
    brgenml1lpr
  ];

  # GUI Packages
  environment.systemPackages = with pkgs; [
    gnomeExtensions.appindicator
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnomeExtensions.user-themes
    gnomeExtensions.syncthing-indicator
    gnome.gnome-tweaks
    gnome.gnome-terminal
    gnome.gnome-themes-extra
    materia-theme
    numix-gtk-theme
    p7zip
    openssl
    keepassxc
    pkg-config
    vscodium
    buildah
    protonvpn-gui
    vlc
    tor-browser-bundle-bin
    jellyfin-media-player
    wireshark
    discord
    graphviz
    google-chrome
    brasero
    signal-desktop
    filezilla
    libreoffice
    joplin-desktop
    bibletime
    firefox
    bitwarden
    virt-manager
  ];

  environment.gnome.excludePackages = with pkgs; [
    gnome.cheese
    gnome.gnome-music
    gnome.totem
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome.epiphany
    gnome-tour
    evolution
  ];

  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
}

