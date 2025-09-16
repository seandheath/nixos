{ config, pkgs, ... }:{
  environment.systemPackages = with pkgs; [
    # GNOME-specific packages not in workstation.nix
    gnomeExtensions.appindicator
    gnomeExtensions.display-configuration-switcher
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnomeExtensions.vitals
    gnome-tweaks
    gnome-terminal
  ];
  environment.gnome.excludePackages = with pkgs; [
    epiphany
    gnome-music
    tali
    iagno
    hitori
    atomix
    gnome-tour
    evolution
  ];
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
}
