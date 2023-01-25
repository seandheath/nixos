# This is the base configuration file, set the hostname and the stateVersion and execute nixos-install
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./users/user.nix
    ];

  networking.hostName =

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

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = 
}

