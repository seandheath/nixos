# systemd-boot on EFI. Every host boots this way; only the generation limit differs.
{ config, lib, ... }:
{
  options.fleet.bootGenerations = lib.mkOption {
    type = lib.types.int;
    default = 10;
    description = "systemd-boot entries to keep. Bounds ESP usage, not store size.";
  };

  config = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.configurationLimit = config.fleet.bootGenerations;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.initrd.systemd.enable = true;
  };
}
