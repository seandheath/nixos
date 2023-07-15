# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:{
  environment.systemPackages = with pkgs; [
    cpupower-gui
    system76-firmware
    system76-keyboard-configurator
    nvtop
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];
  networking.hostName = "osmium"; # Define your hostname.
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
      driSupport = true;
      driSupport32Bit = true;
    };
    system76.enableAll = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  networking.useDHCP = lib.mkDefault true;

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/ac03f934-fa1c-4133-a3a5-c45fa088a833";
      fsType = "f2fs";
    };

  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/5f6760a7-e4bd-4742-a273-ced722eb0d48";

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/02C4-3AD3";
      fsType = "vfat";
    };

  swapDevices = [ ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
