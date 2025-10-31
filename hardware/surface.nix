# Surface tablet hardware configuration
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  # Boot and filesystems - adjust these based on your specific Surface device
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
    "hid-sensor-hub"  # For auto-rotation
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Example filesystem configuration - MODIFY BASED ON YOUR SETUP
  # Uncomment and adjust the following based on your actual partitioning:
  #
  # fileSystems."/" =
  #   { device = "/dev/disk/by-uuid/YOUR-ROOT-UUID";
  #     fsType = "ext4";
  #   };
  #
  # fileSystems."/boot" =
  #   { device = "/dev/disk/by-uuid/YOUR-BOOT-UUID";
  #     fsType = "vfat";
  #     options = [ "fmask=0077" "dmask=0077" ];
  #   };
  #
  # swapDevices = [ ];

  # Graphics and hardware acceleration
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Intel graphics configuration
  hardware.intel-gpu-tools.enable = true;

  # Enable firmware
  hardware.enableRedistributableFirmware = true;

  # CPU configuration for Intel processors
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}