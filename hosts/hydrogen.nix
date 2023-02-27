{ config, pkgs, lib, ... }: {
  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };
  nixpkgs.config.allowUnfree = true;
  services.syncthing.enable = true;
  networking.hostName = "hydrogen"; # Define your hostname.
  networking.wireless.enable = false;
  networking.interfaces.enp5s0.ipv4.addresses = [{
    address = "10.0.0.2";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "10.0.0.1" ];
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
    6789
    7878
    8096
    8989
    14004
  ];
  environment.systemPackages = with pkgs; [
    firefox
    neovim
    git
    curl
    wget
    htop
    tree
    thefuck
    ripgrep
    srm 
    p7zip
  ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  #boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.kernelModules = [ "kvm-intel" ];
  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/acacae35-6fbb-44f7-a80d-673a178405e4";
      fsType = "btrfs";
      options = [
        "noatime"
        "nodiratime"
        "compress=lzo"
        "discard"
      ];
    };

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/4381-F118";
      fsType = "vfat";
    };

  fileSystems."/data" =
    {
      device = "/dev/disk/by-uuid/75c4fbbf-7ab0-42f2-b333-31d825d280c2";
      fsType = "btrfs";
      options = [
        "noatime"
        "nodiratime"
        "compress=lzo"
        "discard"
      ];
    };

  swapDevices =
    [{ device = "/dev/disk/by-uuid/14d0d66b-7286-4a37-a2c0-afc2a9d2ed65"; }];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?
}