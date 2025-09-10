{ config, pkgs, ... }:{
  environment.systemPackages = with pkgs; [
    # GNOME-specific packages not in workstation.nix
    gnomeExtensions.appindicator
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
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
}
