{ lib, pkgs, config, ... }:

let
  dock-monitors = import ../packages/dock-monitors.nix { inherit pkgs; };
in
{
  imports = [
    ../hardware/sulphur.nix
    ../modules/steam.nix
    ../modules/mo2.nix
    ../modules/cemu.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
    ../modules/impermanence.nix
    ../modules/wivrn.nix
  ];

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;

  # Pin to 6.18 until nvidia-open supports kernel 6.19
  boot.kernelPackages = pkgs.linuxPackages_6_18;

  # NVIDIA settings for RTX 50 series
  boot.extraModprobeConfig = ''
    options nvidia NVreg_PreserveVideoMemoryAllocations=1
  '';

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  services.xserver.xkb.layout = "us";

  # Display
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
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
    (callPackage ../packages/jackify.nix {})
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

  # Remap Copilot key (sends shift+meta+f23 simultaneously) to Ctrl layer
  # The combo activates a control layer instead of outputting a key directly
  # Remap M4 button (KEY_PROG1) to Print Screen for screenshots
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings.main = {
        "leftshift+leftmeta" = "layer(control)";
        "prog1" = "sysrq";
      };
    };
  };

  # Touchpad configuration with palm rejection
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      disableWhileTyping = true;
    };
  };

  # Quirks for ASUS touchpad palm detection and keyd integration
  # Lower thresholds = more aggressive palm rejection
  # keyd virtual keyboard must be marked as internal for DWT to work
  environment.etc."libinput/local-overrides.quirks".text = ''
    [ASUS Touchpad]
    MatchUdevType=touchpad
    MatchName=*ASUF1209*
    AttrPalmSizeThreshold=50
    AttrPalmPressureThreshold=70
    AttrThumbSizeThreshold=40
    AttrThumbPressureThreshold=60

    [Keyd Virtual Keyboard]
    MatchUdevType=keyboard
    MatchName=keyd virtual keyboard
    AttrKeyboardIntegration=internal
  '';

  # Services
  services.fwupd.enable = true;

  # Prevent suspend when on AC power (docked)
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "suspend";
    HandleSuspendKey = "suspend";
    IdleAction = "ignore";
  };

  # Reconfigure monitors on display hotplug (e.g. docking station reconnect)
  # Watches for DRM connector change events from the kernel
  services.udev.extraRules = lib.mkAfter ''
    ACTION=="change", SUBSYSTEM=="drm", RUN+="${pkgs.systemd}/bin/systemctl start --no-block dock-monitors-hotplug.service"

    # NVIDIA 580 registers a phantom nvidia_0 backlight (stuck, not wired to the
    # panel) in Hybrid/Optimus mode; the real eDP panel is intel_backlight. The
    # old NVreg_EnableBacklightHandler option was removed upstream, so detach
    # nvidia_0 from the seat - logind drops it and GNOME selects intel_backlight.
    SUBSYSTEM=="backlight", KERNEL=="nvidia_0", TAG-="master-of-seat", ENV{ID_SEAT}=""
  '';

  # System service that runs dock-monitors as the logged-in user on hotplug
  systemd.services.dock-monitors-hotplug = {
    description = "Reapply monitor configuration on display hotplug";
    after = [ "graphical.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Wait for Mutter to detect and enumerate new displays
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${dock-monitors.pythonWithDbus}/bin/python3 ${dock-monitors.script}";
      User = "sheath";
      Environment = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus";
    };
    # Debounce: DRM fires multiple events per dock connect, only run once per 30s
    startLimitIntervalSec = 30;
    startLimitBurst = 1;
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
