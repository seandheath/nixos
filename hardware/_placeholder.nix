# Stand-in so `nixos-rebuild build` evaluates before a machine exists -- the module system
# refuses a system with no root filesystem. install.sh overwrites the per-host file that
# imports this with nixos-generate-config output. A build against this is meaningful; an
# install from it is not.
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # Every host rebuilds from the repo (modules/auto-update.nix), so an installed machine
  # still on the placeholder switches to these dummy filesystems and dies at the next
  # boot. The labels below match what install.sh formats, which keeps that survivable --
  # this says out loud that it is still a dummy.
  warnings = [
    ''
      ${config.networking.hostName}: hardware/${config.networking.hostName}.nix is still the
      placeholder. Commit this machine's nixos-generate-config output over it.
    ''
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];

  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.enableRedistributableFirmware = true;
}
