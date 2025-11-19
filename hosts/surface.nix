# Surface tablet configuration with Sway
{ lib, pkgs, config, ... }:

{
  imports = [
    ../hardware/surface.nix
    ../modules/surface-tablet.nix
    ../modules/surface-sway.nix
  ];

  # Boot configuration for Surface hardware
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10; # Prevent ESP from filling
  boot.initrd.systemd.enable = true;

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Networking
  networking.hostName = "surface";
  networking.networkmanager.enable = true;

  # Disable Phosh and enable Sway
  services.xserver.desktopManager.phosh.enable = false;
  services.greetd = {
    enable = true;
    wayland.enable = true;
    settings = {
      default_session = {
        command = "${pkgs.sway}/bin/sway";
        user = "sheath";
      };
    };
  };

  system.stateVersion = "25.05";
}
