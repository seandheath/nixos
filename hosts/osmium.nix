# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ lib, pkgs, config, ... }:

{
  imports = [
    ../hardware/osmium.nix
    ../modules/gnome.nix
    ../modules/steam.nix
    ../modules/sops.nix
    ../modules/dconf.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
    ../modules/syncthing.nix
    ../modules/auto-update.nix
  ];

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelModules = [ "evdi" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.evdi ];
  boot.initrd.luks.devices."luks-b1189935-07c6-416d-9201-b555aa272104".device = "/dev/disk/by-uuid/b1189935-07c6-416d-9201-b555aa272104";

  # Kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Display
  services.xserver = {
  	enable = true;
	videoDrivers = [ "nvidia" "displaylink" "modesetting" ];
  };
  # DisplayLink
  systemd.services.dlm.wantedBy = [ "multi-user.target" ];

  # Networking
  networking.hostName = "osmium"; # Define your hostname.
  networking.networkmanager.enable = true;

  # Programs
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    system76-firmware
    system76-keyboard-configurator
    displaylink
    zlib
  ];
  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      open = false;
      nvidiaSettings = false;
      modesetting.enable = true;
      powerManagement.enable = true;
      prime = {
        offload.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    graphics = {
      enable = true;
      enable32Bit = true;
    };
    system76.enableAll = true;
  };

  services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";

  system.stateVersion = "25.05";
}
