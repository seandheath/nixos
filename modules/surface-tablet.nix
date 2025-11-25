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
    # Waydroid kernel modules
    "binder_linux"
    "ashmem_linux"
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
    GDK_BACKEND = "wayland";
  };

  # Essential tablet applications
  environment.systemPackages = with pkgs; [
    # Browsers optimized for mobile
    firefox

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

    # Wayland utilities
    wl-clipboard
    wtype              # Wayland xdotool alternative
    ydotool            # Generic input automation

    # Waydroid
    waydroid

    # On-screen keyboard
    onboard
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

  # Waydroid - Android container for running Android apps on tablet
  virtualisation.waydroid.enable = true;
  virtualisation.lxc.enable = true;

  # Kernel modules required for Waydroid
  boot.extraModprobeConfig = ''
    options binder_linux devices="binder,hwbinder,vndbinder"
  '';

  # Networking for Waydroid
  networking.firewall.trustedInterfaces = [ "waydroid0" ];

  # Auto-start Onboard keyboard
  environment.etc."xdg/autostart/onboard-autostart.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Onboard
    Comment=On-screen keyboard
    Exec=onboard --startup-delay=2 --size=1000x300 --dock-expand
    X-GNOME-Autostart-enabled=true
    NoDisplay=true
  '';

  # Onboard keyboard configuration - dock at bottom
  environment.etc."xdg/onboard/onboard-defaults.conf".text = ''
    [main]
    layout=Compact
    theme=Nightshade
    key-label-font=Ubuntu
    key-label-overrides=

    [window]
    docking-enabled=True
    docking-edge=bottom
    docking-shrink-workarea=True
    window-state-sticky=True
    window-decoration=False
    force-to-top=True
    keep-aspect-ratio=False
    transparency=0

    [window.landscape]
    x=0
    y=768
    width=1024
    height=300

    [auto-show]
    enabled=True
    hide-on-key-press=True
  '';

  # Bluetooth support for tablet peripherals
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true;
      };
    };
  };
}
