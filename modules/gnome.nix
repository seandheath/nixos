{ config, pkgs, ... }:{
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  environment.systemPackages = with pkgs; [
    librsvg
    tectonic
    pandoc
    hugo
    mermaid-filter
    mullvad-vpn
    vmware-horizon-client
    element-desktop
    hexo-cli
    prusa-slicer
    openscad
    obsidian
    pavucontrol
    gnomeExtensions.appindicator
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnomeExtensions.vitals
    gnome-tweaks
    gnome-terminal
    vlc
    jellyfin-media-player
    keepassxc
    appimage-run
    brasero
    blightmud
    signal-desktop
    libreoffice-fresh
    google-chrome
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
    epiphany
    gnome.gnome-music
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome-tour
    evolution
  ];
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  services.mullvad-vpn.enable = true;
  services.mullvad-vpn.package = pkgs.mullvad-vpn;
}
