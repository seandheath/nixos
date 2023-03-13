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
  systemd.services.ModemManager.enable = false;
  services.printing.enable = true;
  services.printing.drivers = with pkgs; [
    gutenprint
    gutenprintBin
    brlaser
    brgenml1lpr
  ];

  qt = {
    enable = true;
    style = lib.mkForce "gtk2";
    platformTheme = lib.mkForce "gtk2";
  };
  programs.evolution.enable = lib.mkForce false;

  # GUI Packages
  environment.systemPackages = with pkgs; [
    libsForQt5.qtstyleplugins
    qgnomeplatform
    gnomeExtensions.appindicator
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnomeExtensions.user-themes
    gnomeExtensions.syncthing-indicator
    gnomeExtensions.easyeffects-preset-selector
    gnome.gnome-tweaks
    gnome.gnome-terminal
    gnome.gnome-themes-extra
    gnome.zenity
    materia-theme
    numix-gtk-theme
    p7zip
    openssl
    pkg-config
    buildah
    vlc
    jellyfin-media-player
    wireshark
    graphviz
    google-chrome
    filezilla
    joplin-desktop
    firefox
    easyeffects
    virt-manager
    kicad
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

