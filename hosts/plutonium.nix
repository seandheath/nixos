# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, ... }:

{
  networking.hostName = "plutonium";
  networking.interfaces.enp0s31f6.useDHCP = true;
  networking.interfaces.wlp0s20f3.useDHCP = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/mapper/cryptroot";
      fsType = "btrfs";
    };

  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-uuid/3daf7260-166b-4e38-ab1b-2067eaa509a6";

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/559d5879-a15a-48f1-a26e-e1792cfe6d3c";
      fsType = "btrfs";
    };

  boot.initrd.luks.devices."crypthome".device = "/dev/disk/by-uuid/efe7c328-c994-4454-bed6-a465020b1bd9";

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/0777-932B";
      fsType = "vfat";
    };

  swapDevices = [ ];

  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
# This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.05"; # Did you read the comment?
}
