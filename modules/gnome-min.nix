{ config, pkgs, ... }:
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

  environment.gnome.excludePackages = with pkgs; [
    gnome.cheese
    gnome.gnome-music
    gnome.totem
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome-tour
  ];
}

