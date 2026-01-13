{ lib, pkgs, config, ... }:

{
  imports = [
    ../hardware/sulphur.nix
    ../modules/steam.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
    ../modules/impermanence.nix
  ];

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel for best hardware support on new ASUS hardware
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # NVIDIA settings for RTX 50 series
  boot.extraModprobeConfig = ''
    options nvidia NVreg_PreserveVideoMemoryAllocations=1
  '';

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Display
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" "modesetting" ];
  };

  # Networking
  networking.hostName = "sulphur";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;

  # Programs
  environment.systemPackages = with pkgs; [
    asusctl
    supergfxctl
    zlib
    pciutils
    usbutils
    lshw
    btrfs-progs
  ];

  # ASUS ROG services
  services.asusd = {
    enable = true;
    enableUserService = true;
  };

  services.supergfxd.enable = true;
  systemd.services.supergfxd.path = [ pkgs.pciutils ];

  # Power management
  services.power-profiles-daemon.enable = true;
  services.thermald.enable = true;

  # Hardware configuration
  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      open = true;  # Use open source kernel modules (recommended for RTX 50 series)
      nvidiaSettings = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = true;  # Fine-grained power management for laptops
      package = config.boot.kernelPackages.nvidiaPackages.latest;
      prime = {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        # Bus IDs from lspci output
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        nvidia-vaapi-driver
      ];
    };
  };

  # Remap Copilot key to Right Ctrl
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings.main = {
        f23 = "clearm(shift) clearm(meta) rightcontrol";
      };
    };
  };

  # Services
  services.fwupd.enable = true;

  services.fstrim = {
    enable = true;
    interval = "weekly";
  };

  # Prevent suspend when on AC power (docked)
  services.logind = {
    lidSwitch = "suspend";
    lidSwitchExternalPower = "ignore";
    lidSwitchDocked = "ignore";
    settings.Login = {
      HandlePowerKey = "suspend";
      HandleSuspendKey = "suspend";
      IdleAction = "ignore";
    };
  };

  # GameMode configuration
  programs.gamemode = {
    enable = true;
    settings = {
      general = {
        renice = 10;
      };
      gpu = {
        apply_gpu_optimisations = "accept-responsibility";
        gpu_device = 0;
      };
      custom = {
        start = "${pkgs.libnotify}/bin/notify-send 'GameMode started'";
        end = "${pkgs.libnotify}/bin/notify-send 'GameMode ended'";
      };
    };
  };

  system.stateVersion = "25.11";
}
