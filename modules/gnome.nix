{ config, pkgs, ... }:{
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  environment.systemPackages = with pkgs; [
    obsidian
    pavucontrol
    firefox
    gnomeExtensions.appindicator
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnomeExtensions.vitals
    gnome.gnome-tweaks
    gnome.gnome-terminal
    vlc
    jellyfin-media-player
    keepassxc
    appimage-run
    brasero
    blightmud
    signal-desktop
    libreoffice-fresh
    ungoogled-chromium
    lutris
    wine
    wine64
    wine-wayland
    winetricks
    vscodium
    discord
    xournalpp
  ];
  environment.gnome.excludePackages = with pkgs; [
    gnome.cheese
    gnome.gnome-music
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome.epiphany
    gnome-tour
    evolution
  ];
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    layout = "us";
    xkbVariant = "";
  };
  sound.enable = true;
  hardware.pulseaudio.enable = true;
}
