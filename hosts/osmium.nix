# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:
let
	home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/master.tar.gz";
in {
  imports =
    [ # Include the results of the hardware scan.
      (import "${home-manager}/nixos")
      ../modules/core.nix
      ../modules/gnome.nix
      ../modules/syncthing.nix
      ../users/luckyobserver.nix
    ];

  environment.systemPackages = with pkgs; [
    cpupower-gui
    system76-firmware
    system76-keyboard-configurator
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
  #boot.kernelParams = [ "pci=nommconf" ];

  networking.hostName = "osmium"; # Define your hostname.

  # NVIDIA STUFF
  programs.steam.enable = true;
  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.beta;
      #open = true;
      nvidiaSettings = false;
      modesetting.enable = true;
      powerManagement.enable = true;
      prime = {
        offload.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    opengl = {
      enable = true;
      driSupport32Bit = true;
    };
    system76.enableAll = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/0cf7f777-09db-4fcb-b02e-4246e5d8b987";
      fsType = "ext4";
      options = [ "noatime" ];
    };

  boot.initrd.luks.devices."cryptRoot".device = "/dev/disk/by-uuid/8a311fa5-ab0f-4f2c-8370-0d1af72aba8a";

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/4801-9039";
      fsType = "vfat";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/270cf6b2-4731-45eb-b2cd-bc651323e3cf"; }
    ];

  boot.initrd.luks.devices."cryptSwap".device = "/dev/disk/by-uuid/bf60bcf1-43bf-441e-abe8-d8c74adc518e";

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?
}
