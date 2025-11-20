# Surface tablet module
{ config, lib, pkgs, ... }:

{
  services.upower.enable = true;
  programs.dconf.enable = true;

  # Surface touchscreen daemon (REQUIRED for touchscreen to work)
  services.iptsd = {
    enable = true;
  };

  # Touch input and gesture support
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      scrollMethod = "twofinger";
      disableWhileTyping = true;
      clickMethod = "clickfinger";
      sendEventsMode = "enabled";
    };
    mouse = {
      accelProfile = "flat";  # Disable acceleration for touch
    };
  };

  # Enable touchscreen gesture support
  environment.etc."libinput/local-overrides.quirks".text = ''
    [Touchscreen]
    MatchUdevType=touchscreen
    AttrTouchSizeRange=10:8
    AttrPalmSizeThreshold=800
  '';

  # Screen rotation with IIO sensors
  hardware.sensor.iio = {
    enable = true;
    package = pkgs.iio-sensor-proxy;
  };
  #hardware.microsoft-surface.kernelVersion = "stable";
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  # Surface Type Cover (keyboard) support
  boot.kernelModules = [
    "surface_aggregator"
    "surface_aggregator_registry"
    "surface_hid_core"
    "surface_hid"
  ];

  # Ensure modules load early
  boot.initrd.kernelModules = [ "surface_aggregator" ];

  # Enable all firmware (required for Surface hardware)
  nixpkgs.config.allowUnfree = true;
  hardware.enableRedistributableFirmware = true;
  hardware.enableAllFirmware = true;

  # Surface Pen (stylus) support
  services.xserver.wacom.enable = true;

  # Disable power-profiles-daemon to avoid conflict with TLP
  services.power-profiles-daemon.enable = true;

  # Memory optimization for 4GB RAM systems
  zramSwap = {
    enable = true;
    algorithm = "zstd";  # Best compression/speed balance
    memoryPercent = 40;  # Use up to 40% of RAM
    priority = 10;       # Higher priority than disk swap
    swapDevices = 1;
  };

  # Disk swap as fallback
  swapDevices = [{
    device = "/dev/nvme0n1p3";
    priority = 5;     # Lower than zram
  }];

  # Kernel memory management for low-RAM systems
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;              # Minimal swapping
    "vm.vfs_cache_pressure" = 50;      # Preserve filesystem cache
    "vm.dirty_ratio" = 10;             # Page cache writeback threshold
    "vm.dirty_background_ratio" = 5;   # Background writeback
  };

  # Limit build resources to prevent OOM
  nix.settings = {
    max-jobs = 1;      # Single build at a time
    cores = 2;         # Limit per-build CPU cores
  };

  # Wayland environment variables
  environment.variables = {
    QT_QPA_PLATFORM = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
  };

  # Essential tablet applications
  environment.systemPackages = with pkgs; [
    # Browsers optimized for mobile
    firefox
    epiphany             # GNOME Web browser, scales well

    # Terminal and basic apps
    gnome-terminal
    gnome-calculator
    gnome-text-editor      # Replaces gedit

    # File management
    nautilus

    # Communication and contacts
    gnome-contacts

    # Note-taking and PDF apps
    rnote                 # Handwriting and note-taking
    xournalpp            # PDF annotation with stylus support
    koreader             # E-book reader

    # Drawing and creative apps
    drawing              # Simple drawing app

    # System utilities
    gnome-weather
    gnome-maps

    # Touch input debugging and gesture tools
    libinput             # libinput debug-events, list-devices
    evemu               # evemu-describe for device info
    iio-sensor-proxy    # Provides monitor-sensor utility
    libinput-gestures   # Gesture recognition daemon

    # Wacom/stylus tools
    libwacom

    # GTK themes for better integration
    adwaita-icon-theme
    gnome-themes-extra
  ];

  # Power management commands for suspend/resume
  powerManagement.powerDownCommands = ''
    # Disable wake sources that drain battery
    echo disabled > /sys/bus/usb/devices/usb1/power/wakeup || true
    echo disabled > /sys/bus/usb/devices/usb2/power/wakeup || true

    # Stop power-hungry services before suspend
    systemctl stop bluetooth.service || true
  '';

  powerManagement.resumeCommands = ''
    systemctl start bluetooth.service || true
  '';

  # Udev rules for touch devices and Surface Pen
  services.udev.extraRules = ''
    # Surface touchscreen and pen access
    SUBSYSTEM=="input", ATTRS{name}=="*IPTS*", MODE="0660", TAG+="uaccess"
    SUBSYSTEM=="input", ATTRS{name}=="*Pen*", MODE="0660", TAG+="uaccess"
    SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="*Touch*", MODE="0660", TAG+="uaccess"

    # Surface Type Cover keyboard detection
    SUBSYSTEM=="input", ATTRS{name}=="*Surface*", MODE="0660", TAG+="uaccess"
    ACTION=="add", SUBSYSTEM=="hid", DRIVER=="surface_hid", RUN+="${pkgs.systemd}/bin/systemctl restart display-manager.service"
  '';

  # Example hwdb entry for touch calibration (adjust for your device)
  # services.udev.extraHwdb = ''
  #   evdev:input:b0003v045Ep*
  #    LIBINPUT_CALIBRATION_MATRIX=1.0 0.0 0.0 0.0 1.0 0.0
  # '';

  # Example orientation matrix for auto-rotation (adjust for your Surface model)
  # services.udev.extraHwdb = ''
  #   sensor:modalias:acpi:INVN6500*:dmi:*svnMicrosoft*Corporation*:*pnSurface*Pro*
  #    ACCEL_MOUNT_MATRIX=0, 1, 0; -1, 0, 0; 0, 0, 1
  # '';
}
