# PLACEHOLDER -- not this machine's real hardware.
#
# install.sh overwrites this file with nixos-generate-config output when the laptop is
# actually installed (see HARDWARE_DEST in install.sh). It exists now so that
# `nixos-rebuild build --flake .#gentlemenpupil` evaluates and the rest of the
# configuration can be tested before the hardware is in hand: the module system refuses
# to evaluate a system with no root filesystem.
#
# A build against this file is meaningful; a system installed from it is not.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.enableRedistributableFirmware = true;
}
