{ config, pkgs, lib, ... }:
let
  nv = pkgs.writeShellScriptBin "nv" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec -a "$0" "$@"
  '';
in
{
  imports = [
    ../home/home-osmium.nix
  ];
  programs.steam.enable = true;
  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    nvidia = {
      package = config.boot.kernelPackages.nvidiaPackages.beta;
      open = true;
      nvidiaSettings = false;
      nvidiaPersistenced = true;
      modesetting.enable = true;
      prime = {
        offload.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    opengl = {
      enable = true;
      driSupport32Bit = true;
    };
    system76.enableAll = true;
  };
  nixpkgs.config.allowUnfree = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  services.logind = {
    lidSwitch = "suspend-then-hibernate";
    extraConfig = ''
      HandlePowerKey=suspend-then-hibernate
      IdleAction=suspend-then-hibernate
      IdleActionSec=2m
    '';
  };

  networking.hostName = "osmium"; # Define your hostname.
  networking.networkmanager.enable = true; # Easiest to use and most distros use this by default.

  environment.systemPackages = with pkgs; [
    firefox
    neovim
    git
    curl
    wget
    htop
    tree
    pciutils
    glxinfo
    mesa-demos
    vulkan-tools
    system76-firmware
    system76-keyboard-configurator
    nv
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  #boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.extraModulePackages = with config.boot.kernelPackages; [
    #system76-acpi
    system76-io
    system76-power
  ];
  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.kernelModules = [ "kvm-intel" ];
  #boot.kernelParams = [ "mem_sleep_default=deep" ];
  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/0bf1b570-dcf4-4306-9370-0bd5151e9c74";
      fsType = "xfs";
      options = [ "noatime" ];
    };

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/34C6-1652";
      fsType = "vfat";
    };
  boot.initrd.luks.devices."cryptRoot".device = "/dev/disk/by-uuid/27f28004-bc78-4ec4-9afa-7dce3b0465cc";

  fileSystems."/home" =
    {
      device = "/dev/disk/by-uuid/b7b566b4-a3dc-460a-b22b-f0219b6f584c";
      fsType = "xfs";
      options = [ "noatime" ];
    };
  boot.initrd.luks.devices."cryptHome".device = "/dev/disk/by-uuid/3745008b-bb3c-438c-b45c-31d3badfaffb";

  swapDevices =
    [{
      device = "/dev/disk/by-uuid/491b12ab-1a4f-4041-9f88-c8190c1d1e03";
    }];
  boot.resumeDevice = "/dev/disk/by-uuid/491b12ab-1a4f-4041-9f88-c8190c1d1e03";
  security.protectKernelImage = false;
  boot.initrd.luks.devices."cryptSwap".device = "/dev/disk/by-uuid/60ef28d4-9818-4155-acbb-b49bc56d533c";

  networking.useDHCP = lib.mkDefault true;
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
