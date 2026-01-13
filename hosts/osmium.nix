# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ lib, pkgs, config, ... }:

{
  imports = [
    ../hardware/osmium.nix
    ../modules/steam.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
  ];

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # DisplayLink evdi module - disabled due to framebuffer conflicts
  # boot.kernelModules = [ "evdi" ];
  # boot.extraModulePackages = [ config.boot.kernelPackages.evdi ];
  boot.initrd.luks.devices."luks-b1189935-07c6-416d-9201-b555aa272104".device = "/dev/disk/by-uuid/b1189935-07c6-416d-9201-b555aa272104";
  boot.extraModprobeConfig = ''
    options nvidia NVreg_PreserveVideoMemoryAllocations=1
  '';

  # Kernel
  #boot.kernelPackages = pkgs.linuxPackages_zen;

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
  # DisplayLink - temporarily disabled due to build issues
  # systemd.services.dlm.wantedBy = [ "multi-user.target" ];

  # Networking
  networking.hostName = "osmium"; # Define your hostname.
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;  # Disable for better gaming/streaming performance

  # Programs
  environment.systemPackages = with pkgs; [
    system76-firmware
    system76-keyboard-configurator
    # displaylink
    zlib
  ];
  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      #package = config.boot.kernelPackages.nvidiaPackages.beta;
      open = false;
      nvidiaSettings = true;
      modesetting.enable = true;
      powerManagement.enable = true;  # Enable for better stability and battery life
      nvidiaPersistenced = true;  # Keep GPU initialized to prevent falling off bus
      prime = {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
      powerManagement.finegrained = false;  # Disabled - causes GPU disconnection issues
    };
    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        intel-media-driver  # VAAPI for Intel (newer)
        intel-vaapi-driver  # VAAPI for Intel (older - renamed from vaapiIntel)
        libva-vdpau-driver  # VDPAU backend for VAAPI
        libvdpau-va-gl
        nvidia-vaapi-driver  # VAAPI for NVIDIA
      ];
    };
    system76.enableAll = true;
  };

  # Force NVIDIA for all Vulkan operations (avoid Intel Vulkan driver hangs)
  environment.sessionVariables = {
    VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json";
  };

  # Services
  services.system76-scheduler.enable = true;  # Optimized process scheduling for System76 hardware
  services.fstrim = {
    enable = true;
    interval = "weekly";  # Maintain SSD performance
  };

  # Prevent suspend when on AC power (docked)
  services.logind = {
    lidSwitch = "suspend";                    # Default when on battery
    lidSwitchExternalPower = "ignore";        # Ignore lid when on AC
    lidSwitchDocked = "ignore";               # Ignore lid when docked
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

  system.stateVersion = "25.05";
}
