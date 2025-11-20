# Surface tablet configuration with Sway
{ lib, pkgs, config, ... }:

{
  imports = [
    ../hardware/surface.nix
    ../modules/surface-tablet.nix
    ../modules/surface-gnome.nix
    ../modules/auto-update.nix
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

  # SSH server
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  # Open SSH port in firewall
  networking.firewall.allowedTCPPorts = [ 22 ];

  system.stateVersion = "25.05";
}
