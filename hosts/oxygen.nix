{ config, lib, pkgs, ... }: {
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
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.brlaser ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod" ];
  boot.kernelModules = [ "kvm-amd" ];
  fileSystems."/" =
  { 
    device = "/dev/disk/by-uuid/cfa03003-a0ef-48eb-8c93-2f283a4d9e3e";
    fsType = "ext4";
  };

  boot.initrd.luks.devices."cryptroot".device = "/dev/disk/by-id/md-name-nixos:0";

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/CF66-57EF";
      fsType = "vfat";
    };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
