# Surface tablet module with Phosh mobile desktop environment
{ config, lib, pkgs, ... }:

{
  # Phosh desktop environment for mobile interface
  services.xserver.desktopManager.phosh = {
    enable = true;
    user = "sheath";
    group = "users";
    phocConfig = {
      xwayland = "immediate";  # Enable X11 app compatibility
    };
  };

  # Required services for Phosh
  services.gnome = {
    gnome-keyring.enable = true;
    evolution-data-server.enable = true;
  };

  services.upower.enable = true;
  programs.dconf.enable = true;

  # Touch input and gesture support
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      scrollMethod = "twofinger";
      disableWhileTyping = true;
      clickMethod = "clickfinger";
    };
    mouse = {
      accelProfile = "flat";  # Disable acceleration for touch
    };
  };

  # Screen rotation with IIO sensors
  hardware.sensor.iio = {
    enable = true;
    package = pkgs.iio-sensor-proxy;
  };
  #hardware.microsoft-surface.kernelVersion = "stable";
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

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
    GDK_BACKEND = "wayland";
    MOZ_ENABLE_WAYLAND = "1";
  };

  # Essential tablet applications
  environment.systemPackages = with pkgs; [
    # Mobile interface essentials
    phosh-mobile-settings  # Essential settings app
    squeekboard           # On-screen keyboard

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

    # Touch input debugging tools
    libinput             # libinput debug-events, list-devices
    evemu               # evemu-describe for device info
    iio-sensor-proxy    # Provides monitor-sensor utility

    # Wacom/stylus tools
    libwacom

    # GTK themes for better integration
    adwaita-icon-theme
    gnome-themes-extra
  ];

  # Squeekboard on-screen keyboard service
  systemd.user.services.squeekboard = {
    description = "Squeekboard virtual keyboard";
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.squeekboard}/bin/squeekboard";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

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

  # Disable resource-intensive services for low-RAM systems
  services.gnome.tinysparql.enable = false;        # File indexing
  services.gnome.localsearch.enable = false;  # Content extraction

  # Udev rules for touch devices and Surface Pen
  services.udev.extraRules = ''
    # Surface Pen detection
    SUBSYSTEM=="input", ATTRS{name}=="*Pen*", MODE="0660", TAG+="uaccess"
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
