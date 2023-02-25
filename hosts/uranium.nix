{ config, lib, pkgs, modulesPath, ... }:
{
  networking.hostName = "uranium"; # Define your hostname.
  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/a63da51c-e43b-4256-aa09-23369fc915d0";
      fsType = "btrfs";
    };

  boot.initrd.luks.devices."crypt".device = "/dev/disk/by-uuid/7da5fc35-9fec-4702-9dc5-bf566945c2bb";

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/6AE1-228E";
      fsType = "vfat";
    };

  swapDevices =
    [{ device = "/dev/disk/by-uuid/fb6817b2-b8e0-49d0-b80d-0095ebb81544"; }];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?

}
