{ config, pkgs, lib, ... }:
let
  nv = pkgs.writeShellScriptBin "nv" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    exec -a "$0" "$@"
  '';
in {
  environment.persistence."/nix/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/etc/NetworkManager/system-connections"
      "/var/log"
      "/var/lib/systemd/coredump"
      "/var/lib/bluetooth"
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "0750"; }
    ];
    files = [
      "/etc/machine-id"
    ];
    users.lo = {
      directories = [
        "Desktop"
	"Documents"
        "Downloads"
	"Music"
	"Pictures"
	"Public"
	"Templates"
	"Videos"
	"Sync"
	"vms"
	"workspace"
	".mozilla"
	{ directory = ".gnupg"; mode = "0700"; }
	{ directory = ".ssh"; mode = "0700"; }
	{ directory = ".nixops"; mode = "0700"; }
	{ directory = ".local/share/keyrings"; mode = "0700"; }
	".local/share/direnv"
      ];
    };
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    nvidia = {
      #open = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = true;
      prime = {
        offload.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    opengl = {
      enable = true;
      driSupport32Bit = true;
      extraPackages = with pkgs; [
        vaapiIntel
        vaapiVdpau
        libvdpau-va-gl
      ];
      extraPackages32 = with pkgs; [
        libva
        vaapiIntel
      ];
    };
    system76.enableAll = true;
  };    
  nixpkgs.config.allowUnfree = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_zen;
  networking.hostName = "osmium"; # Define your hostname.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.mutableUsers = false;

  # Optimise store
  nix.settings.auto-optimise-store = true;

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
    nv
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" "sdhci_pci" ];
  boot.kernelModules = [ "kvm-intel" ];

  fileSystems."/" =
    { device = "none";
      fsType = "tmpfs";
      options = [ "defaults" "size=8G" "mode=755" "noatime" ];
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/3240-65FD";
      fsType = "vfat";
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/748003a2-74e0-4111-bd1e-0dd3cd513b86";
      fsType = "ext4";
      options = [ "noatime" ];
      neededForBoot = true;
    };

  boot.initrd.luks.devices."cryptRoot".device = "/dev/md127";

  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?
}
