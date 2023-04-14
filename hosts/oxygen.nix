{ config, lib, pkgs, ... }: {
  imports = [
    ../modules/core.nix
    ../modules/gnome.nix
    ../modules/syncthing.nix
    ../users/luckyobserver.nix
  ];
  networking.hostName = "oxygen";
  networking = {
    interfaces = {
      enp4s0 = {
        useDHCP = false;
        ipv4.addresses = [{
          address = "10.0.0.10";
          prefixLength = 24;
        }];
        mtu = 9000;
      };
    };
    defaultGateway = "10.0.0.1";
    nameservers = [ "10.0.0.1" ];
    firewall = {
      enable = true;
    };
  };
  programs.steam.enable = true;
  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.beta;
      modesetting.enable = true;
      powerManagement.enable = true;
    };
    opengl.enable = true;
    opengl.driSupport32Bit = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
  boot.kernelModules = [ "kvm-amd" ];
  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/75d37fb7-2cff-4cc2-8e1a-29d612bdd0fe";
      fsType = "btrfs";
      options = [ "noatime" ];
    };
  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/0CBC-0A69";
      fsType = "vfat";
    };
  fileSystems."/home" =
    {
      device = "/dev/disk/by-uuid/3fa331a2-eeb6-43e7-a8d0-8ae4f739c568";
      fsType = "btrfs";
      options = [ "noatime" ];
    };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.video.hidpi.enable = lib.mkDefault true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?

}
