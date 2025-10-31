# Surface tablet configuration with Phosh mobile desktop environment
{ lib, pkgs, config, ... }:

{
  imports = [
    ../hardware/surface.nix
    ../modules/surface-tablet.nix
  ];

  # Boot configuration for Surface hardware
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10; # Prevent ESP from filling

  # Surface-specific kernel parameters
  boot.kernelParams = [
    "i915.enable_psr=0"  # Mitigate screen flicker
    "mem_sleep_default=s2idle"
    "i915.enable_dc=2"     # Intel display power saving
  ];

  # Kernel modules for Surface Aggregator Module (SAM) support in initrd
  boot.initrd.kernelModules = [
    "surface_aggregator"
    "surface_aggregator_registry"
    "surface_aggregator_hub"
    "surface_hid_core"
    "surface_hid"
    "pinctrl_tigerlake"  # Adjust for your CPU generation
    "intel_lpss"
    "intel_lpss_pci"
    "8250_dw"
  ];

  boot.initrd.systemd.enable = true;

  # Surface hardware support from nixos-hardware
  # The microsoft-surface-common module provides Surface-specific kernel and firmware
  # but may not include all options like ipts - check nixos-hardware documentation

  # Uncomment for Surface Go 1 WiFi firmware fix
  # hardware.microsoft-surface.firmware.surface-go-ath10k.replace = true;

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  # Networking
  networking.hostName = "surface";
  networking.networkmanager.enable = true;

  system.stateVersion = "25.05";
}