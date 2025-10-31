# Installing NixOS with Phosh on Surface Tablets: Complete Guide

**NixOS with Phosh runs successfully on Microsoft Surface tablets through the nixos-hardware project, which integrates linux-surface kernel patches.** The installation requires disabling Secure Boot initially, using specialized kernel modules for touchscreen and stylus support, and careful memory management for 4GB RAM systems. Phosh is fully supported in nixpkgs without requiring mobile-nixos for desktop installations, though kernel compilation takes 4+ hours on-device and should be performed on a remote build server. Surface devices achieve good hardware compatibility but battery life runs 25-40% worse than Windows due to Connected Standby (s2idle) limitations rather than deep sleep support.

This matters because Surface tablets represent an accessible entry point for mobile Linux computing, combining reasonable pricing with good Linux hardware support when properly configured. The declarative nature of NixOS provides unique advantages for tablet configurations, enabling atomic rollbacks when experiments fail and reproducible setups across devices. The main complexity lies in the initial setup combining three distinct projects: NixOS's unique package management, linux-surface's hardware patches, and Phosh's mobile-optimized interface.

Surface hardware support improved significantly in 2024 through the official nixos-hardware repository, which now provides pre-configured modules for Surface Go, Pro, Laptop, and Book models. The linux-surface project maintains active development with kernel patches merged into nixos-hardware, eliminating the need for manual patch application. Phosh reached version 0.44.1 in late 2024 with improved text input support and gesture handling, though the GTK4 migration remains incomplete.

## Surface-specific installation starts with hardware module integration

The recommended installation method uses **nixos-hardware modules rather than manual linux-surface configuration**, dramatically simplifying the setup process. Surface devices require specialized drivers for the Surface Aggregator Module (SAM) that controls the keyboard and touchpad, Intel Precise Touch and Stylus (IPTS) for touchscreen and pen input, and device-specific WiFi firmware particularly for Surface Go models using Qualcomm ath10k chipsets.

Begin by downloading the NixOS ISO (23.11 or later) and creating a bootable USB drive. Access the Surface UEFI by holding Volume Up while powering on, then disable Secure Boot—required for the initial installation but re-enableable later using lanzaboote. On Surface devices, disabling Secure Boot automatically enters "setup mode" which simplifies later secure boot re-enrollment. You'll need a USB hub for Surface Go and similar single-port models to connect both the installer USB and keyboard during installation.

Partition the storage using a GPT layout with a 512MB-1GB EFI System Partition (ESP) formatted as FAT32 and mounted at /boot, plus a root partition using ext4, btrfs, or LUKS-encrypted ext4. If dual-booting with Windows, resize the existing 100MB ESP to at least 512MB before installation since **NixOS requires more ESP space than Windows** to store multiple kernel generations. Use these commands for a fresh installation:

```bash
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP fat32 1MB 1GB
parted /dev/nvme0n1 -- set 1 esp on
parted /dev/nvme0n1 -- mkpart root ext4 1GB 100%

mkfs.fat -F 32 -n boot /dev/nvme0n1p1
mkfs.ext4 -L nixos /dev/nvme0n1p2

mount /dev/nvme0n1p2 /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
```

Complete the standard NixOS installation with `nixos-generate-config --root /mnt` and `nixos-install`. After rebooting into the base system, configure the Surface-specific hardware support through a flake-based setup:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }: {
    nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        nixos-hardware.nixosModules.microsoft-surface-go
        # Or: microsoft-surface-pro-9
        # Or: microsoft-surface-common
      ];
    };
  };
}
```

The critical consideration is **kernel compilation time**: building the linux-surface kernel on the Surface device itself takes 4+ hours and drains the battery. Set up distributed builds or use a remote build server by adding this to your configuration:

```nix
nix.buildMachines = [{
  hostName = "build-server.local";
  system = "x86_64-linux";
  maxJobs = 8;
  speedFactor = 2;
  supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" ];
}];
```

Alternatively, build on a powerful machine with `nixos-rebuild build --flake .#surface`, copy the closure with `nix copy --to "ssh://user@surface" ./result`, then switch on the Surface device. This approach saves hours and prevents battery depletion during compilation.

## Bootloader configuration requires specific kernel modules for LUKS support

Use systemd-boot as the default bootloader since it provides simple UEFI integration and automatic Windows detection on shared ESP partitions:

```nix
boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = true;
boot.loader.systemd-boot.configurationLimit = 10;  # Prevent ESP from filling
```

The `configurationLimit` setting prevents the 512MB ESP from filling with old kernel generations. If using full-disk encryption with LUKS, the Type Cover keyboard requires specific kernel modules loaded in the initrd to function at the password prompt:

```nix
boot.initrd.kernelModules = [
  "surface_aggregator"
  "surface_aggregator_registry"
  "surface_aggregator_hub"
  "surface_hid_core"
  "surface_hid"
  "pinctrl_tigerlake"  # Adjust for your CPU generation
  "intel_lpss"
  "intel_lpss_pci"
  "8250_dw"
];

boot.initrd.systemd.enable = true;
```

Enable Surface-specific kernel parameters to address common issues like screen flickering on Intel graphics and configure the hardware modules:

```nix
boot.kernelParams = [
  "i915.enable_psr=0"  # Mitigate screen flicker
];

microsoft-surface = {
  kernelVersion = "stable";  # or "longterm"
  ipts.enable = true;        # Touch and stylus support
  surface-control.enable = true;  # Performance modes
};
```

Surface Go 1 specifically requires WiFi firmware replacement to fix "Can't ping firmware" errors with the Qualcomm ath10k chipset:

```nix
hardware.microsoft-surface.firmware.surface-go-ath10k.replace = true;
```

This destructively replaces all ath10k QCA6174 firmware files, so only enable it for affected devices.

## Phosh desktop environment configures directly without mobile-nixos

The mobile-nixos project focuses on device-specific hardware support for actual mobile phones like PinePhone and Librem 5, but **Phosh runs directly on NixOS through nixpkgs without mobile-nixos for Surface tablets**. The desktop manager module provides complete Phosh support including the phoc compositor, session management, and required GNOME services.

Configure Phosh with this minimal setup in your configuration.nix:

```nix
services.xserver.desktopManager.phosh = {
  enable = true;
  user = "youruser";
  group = "users";
  phocConfig = {
    xwayland = "immediate";  # Enable X11 app compatibility
  };
};

hardware.sensor.iio.enable = true;  # Auto-rotation
services.upower.enable = true;
networking.networkmanager.enable = true;

services.gnome = {
  gnome-keyring.enable = true;
  evolution-data-server.enable = true;
};

environment.systemPackages = with pkgs; [
  phosh-mobile-settings  # Essential settings app
  squeekboard           # On-screen keyboard
  firefox-wayland
  gnome.gnome-terminal
  gnome.gnome-contacts
  epiphany             # GNOME Web browser, scales well
];
```

Phosh uses **phoc**, a wlroots-based Wayland compositor specifically designed for mobile interfaces. The compositor automatically starts through systemd services when you boot the system, bypassing traditional display managers. Users log in via Phosh's built-in lockscreen which requires setting a numeric password:

```nix
users.users.youruser = {
  isNormalUser = true;
  initialPassword = "147147";  # Change after first login
  extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
};
```

Phosh version 0.44.1 in nixpkgs includes recent improvements to text input, fling gesture handling, and mobile data quick settings. The interface provides native gestures including swipe down from the top bar for quick settings and notifications, and swipe up from the bottom bar for the app launcher. For additional custom gestures, integrate lisgd (libinput swipe gesture daemon) as a systemd user service.

Set environment variables to ensure applications use Wayland protocols correctly:

```nix
environment.variables = {
  QT_QPA_PLATFORM = "wayland";
  GDK_BACKEND = "wayland";
  MOZ_ENABLE_WAYLAND = "1";
};
```

## Touch input and gestures work through libinput with Surface kernel patches

Touch screen support on Surface tablets requires the linux-surface IPTS (Intel Precise Touch and Stylus) daemon enabled through the microsoft-surface module. Configure libinput to handle multi-touch input with appropriate settings for tablet use:

```nix
services.xserver.libinput = {
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
```

For device-specific touch calibration, use udev rules with the libinput calibration matrix. First, identify your touch device with `libinput list-devices`, then create a hwdb entry:

```nix
services.udev.extraHwdb = ''
  evdev:input:b0003v045Ep*
   LIBINPUT_CALIBRATION_MATRIX=1.0 0.0 0.0 0.0 1.0 0.0
'';
```

The calibration matrix values derive from a 9-point calibration process where a=(screen_width * 6/8)/(click_3_X - click_0_X) and similar calculations for other coordinates. Most Surface devices don't require manual calibration when using the linux-surface kernel, but the option exists for fine-tuning.

Install debugging tools for touch troubleshooting:

```nix
environment.systemPackages = with pkgs; [
  libinput       # libinput debug-events, list-devices
  evemu          # evemu-describe for device info
  xorg.xinput    # Runtime calibration for X11
];
```

Test touch functionality with `libinput debug-events` to monitor real-time touch input, or use `evtest /dev/input/eventX` to verify multi-touch coordinates and pressure values.

## Squeekboard on-screen keyboard requires session integration and dconf

Squeekboard, Phosh's on-screen keyboard, integrates through the GNOME accessibility framework and requires proper dconf configuration to appear automatically:

```nix
environment.systemPackages = with pkgs; [
  squeekboard
];

programs.dconf.enable = true;

services.gnome.gnome-keyring.enable = true;

systemd.user.services.squeekboard = {
  description = "Squeekboard virtual keyboard";
  wantedBy = [ "graphical-session.target" ];
  serviceConfig = {
    ExecStart = "${pkgs.squeekboard}/bin/squeekboard";
    Restart = "on-failure";
    RestartSec = "5s";
  };
};
```

Enable the accessibility on-screen keyboard setting via gsettings after first login:

```bash
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
```

Squeekboard automatically appears when text input fields gain focus in Phosh, though it won't show in "Docked mode" which you can toggle in the top menu. The keyboard supports multiple layouts stored in `/run/current-system/sw/share/squeekboard/keyboards/` with custom layouts placeable in `~/.local/share/squeekboard/keyboards/`.

For manual control, use D-Bus commands:

```bash
# Show keyboard
busctl call --user sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b true

# Hide keyboard
busctl call --user sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b false
```

If Squeekboard fails to start, check the logs with `journalctl --user -u squeekboard` and verify that the Phosh session is active with GNOME session management enabled.

## Screen rotation uses iio-sensor-proxy for automatic orientation detection

Enable automatic screen rotation through the IIO sensor infrastructure which reads accelerometer data and communicates orientation changes to Phosh:

```nix
hardware.sensor.iio = {
  enable = true;
  package = pkgs.iio-sensor-proxy;
};

boot.initrd.availableKernelModules = [ "hid-sensor-hub" ];

environment.systemPackages = with pkgs; [
  iio-sensor-proxy  # Provides monitor-sensor utility
];
```

Surface devices sometimes require orientation matrix configuration to correctly interpret accelerometer data. Add device-specific calibration through udev hwdb entries:

```nix
services.udev.extraHwdb = ''
  sensor:modalias:acpi:INVN6500*:dmi:*svnMicrosoft*Corporation*:*pnSurface*Pro*
   ACCEL_MOUNT_MATRIX=0, 1, 0; -1, 0, 0; 0, 0, 1
'';
```

The mount matrix rotates accelerometer coordinates to match the physical device orientation. Determine the correct matrix for your device using `udevadm info --export-db | grep -A 10 "ACCEL_MOUNT_MATRIX"` and test with `monitor-sensor` which displays current orientation readings.

Phosh automatically rotates the display when iio-sensor-proxy reports orientation changes, with no additional configuration required. Lock rotation through Phosh Mobile Settings or via gsettings:

```bash
# Lock rotation
gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation-lock true

# Set specific orientation
gsettings set org.gnome.settings-daemon.peripherals.touchscreen orientation 'normal'
```

For manual rotation testing or troubleshooting, use wlr-randr on Phosh's wlroots-based phoc compositor:

```bash
wlr-randr --output eDP-1 --transform normal|90|180|270
```

Monitor orientation events in real-time by watching the D-Bus interface: `busctl monitor --user net.hadess.SensorProxy`.

## Surface Pen configuration requires Wacom protocol support and pressure curves

Surface Pen uses the Wacom protocol and requires both kernel-level support through IPTS and userspace configuration through libwacom. The nixos-hardware Surface modules include necessary kernel support, but additional configuration optimizes stylus behavior:

```nix
services.xserver.wacom.enable = true;

environment.systemPackages = with pkgs; [
  xorg.xf86inputwacom
  libwacom
  libwacom-surface  # Surface-specific device data
];

services.udev.extraRules = ''
  # Surface Pen detection
  SUBSYSTEM=="input", ATTRS{name}=="*Pen*", MODE="0660", TAG+="uaccess"
'';
```

On Wayland with Phosh, libinput automatically handles stylus input including pressure sensitivity. Test stylus detection and functionality with these commands:

```bash
# List input devices
libinput list-devices

# Monitor stylus events
libinput debug-events --device /dev/input/eventX

# For X11 applications, configure Wacom driver
xsetwacom --list devices
xsetwacom --set "Surface Pen stylus" PressureCurve 0 0 100 100
```

Pressure curves adjust stylus sensitivity with format "x1 y1 x2 y2" where softer response uses "0 0 50 100" and harder response uses "0 0 100 50". Make pressure settings permanent through session commands:

```nix
services.xserver.displayManager.sessionCommands = ''
  sleep 2
  ${pkgs.xorg.xf86inputwacom}/bin/xsetwacom --set "Surface Pen stylus" \
    PressureCurve 0 0 80 100
'';
```

Surface Pen buttons map through udev with keyboard event codes. The barrel button typically maps to right-click, while the eraser end switches to eraser mode automatically in supported applications.

libwacom-surface extends the base libwacom database with Surface-specific stylus information including button mappings and pressure ranges. Verify libwacom recognizes your stylus with `libwacom-list-devices` and check for Surface Pen entries.

## Tablet applications install from nixpkgs with specific considerations

The three requested applications are all available in nixpkgs with varying levels of touch optimization and stability.

**rnote** provides handwriting and note-taking with vector graphics support but has known settings persistence issues:

```nix
environment.systemPackages = with pkgs; [
  rnote
];
```

Users report crashes with the selector tool and color picker in some versions (Issue #369962 in nixpkgs). For better stability, consider using the Flatpak version or xournalpp as an alternative. rnote excels at infinite canvas sketching and supports stylus pressure sensitivity when configured properly.

**xournalpp** offers mature PDF annotation and handwriting with excellent stylus support but requires GTK theme dependencies:

```nix
environment.systemPackages = with pkgs; [
  xournalpp
  adwaita-icon-theme
  gnome.gnome-themes-extra
];

programs.dconf.enable = true;
```

xournalpp provides pressure-sensitive drawing, PDF annotation, handwriting recognition through optional plugins, and Lua scripting for customization. Enable Lua support with the package override `xournalpp.override { withLua = true; }`. The application scales reasonably on tablet screens and supports both finger touch and stylus input simultaneously.

**koreader** works as a versatile e-book reader supporting PDF, DjVu, EPUB, FB2, CBZ, and many other formats:

```nix
environment.systemPackages = with pkgs; [
  koreader
];
```

Originally designed for e-ink readers, koreader adapts well to backlit tablet screens with extensive customization options. Configuration stores in `$XDG_CONFIG_HOME/koreader` with touch-optimized navigation and gesture controls. The application performs well on resource-constrained systems, making it ideal for 4GB RAM tablets.

Add tablet-friendly auxiliary applications:

```nix
environment.systemPackages = with pkgs; [
  gnome.gnome-calculator
  gnome-text-editor      # Replaces gedit
  drawing               # Simple drawing app
  gnome.gnome-weather
  gnome.gnome-maps
  portfolio             # File manager
];
```

Choose applications built with GTK4 and libadwaita for best integration with Phosh's mobile interface and proper scaling behavior.

## Memory optimization for 4GB RAM requires zram and careful service management

NixOS has **significant memory overhead during system operations**, with `nixos-rebuild switch` consuming 500MB-1.2GB RAM and system evaluation alone using approximately 500MB-1GB. This makes memory optimization critical for 4GB systems that need to maintain headroom for applications while supporting system maintenance.

Implement zram compressed swap as the primary strategy, providing fast compressed memory in RAM rather than disk I/O:

```nix
zramSwap = {
  enable = true;
  algorithm = "zstd";  # Best compression/speed balance
  memoryPercent = 40;  # Use up to 40% of RAM
  priority = 10;       # Higher priority than disk swap
  swapDevices = 1;
};
```

Add a small disk swap file as fallback for memory pressure spikes:

```nix
swapDevices = [{
  device = "/var/lib/swapfile";
  size = 4 * 1024;  # 4GB
  priority = 5;     # Lower than zram
}];
```

Configure kernel memory management parameters to reduce swap aggressiveness and preserve cache:

```nix
boot.kernel.sysctl = {
  "vm.swappiness" = 10;              # Minimal swapping
  "vm.vfs_cache_pressure" = 50;      # Preserve filesystem cache
  "vm.dirty_ratio" = 10;             # Page cache writeback threshold
  "vm.dirty_background_ratio" = 5;   # Background writeback
};
```

Limit build parallelism to prevent memory exhaustion during package compilation:

```nix
nix.settings = {
  max-jobs = 1;      # Single build at a time
  cores = 2;         # Limit per-build CPU cores
};
```

Disable resource-intensive services that provide minimal value on tablets:

```nix
services.gnome.tracker.enable = false;        # File indexing
services.gnome.tracker-miners.enable = false;  # Content extraction
```

For system updates on constrained memory, close all applications and use these commands:

```bash
# Clear old generations
sudo nix-collect-garbage -d

# Rebuild with minimal resources
sudo nixos-rebuild switch --max-jobs 1 --cores 1
```

Monitor memory usage during rebuilds with `watch -n 1 free -h` to identify if additional optimization is needed. If rebuilds consistently fail with out-of-memory errors, set up a remote build server as described in the installation section.

The combination of zram (fast compressed swap), small disk swap (overflow protection), low swappiness (prefer caching), and limited build parallelism creates a stable environment for NixOS operation on 4GB RAM while maintaining reasonable performance.

## Power management uses TLP or auto-cpufreq with Surface-specific tuning

Configure comprehensive power management through TLP, which provides extensive control over CPU governors, frequency scaling, and device power states:

```nix
services.tlp = {
  enable = true;
  settings = {
    CPU_SCALING_GOVERNOR_ON_AC = "performance";
    CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
    
    CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
    CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
    
    CPU_MIN_PERF_ON_BAT = 0;
    CPU_MAX_PERF_ON_BAT = 30;  # Limit to 30% on battery
    CPU_BOOST_ON_BAT = 0;      # Disable turbo boost
    CPU_BOOST_ON_AC = 1;
    
    START_CHARGE_THRESH_BAT0 = 40;  # Battery longevity
    STOP_CHARGE_THRESH_BAT0 = 80;
    
    PLATFORM_PROFILE_ON_AC = "performance";
    PLATFORM_PROFILE_ON_BAT = "low-power";
    
    WIFI_PWR_ON_AC = "off";
    WIFI_PWR_ON_BAT = "on";
    
    USB_AUTOSUSPEND = 1;
    USB_EXCLUDE_PHONE = 1;
  };
};
```

Alternatively, use auto-cpufreq for automatic CPU frequency management without manual tuning (note: conflicts with TLP, choose one):

```nix
services.tlp.enable = false;

services.auto-cpufreq = {
  enable = true;
  settings = {
    battery = {
      governor = "powersave";
      turbo = "never";
      scaling_min_freq = 800000;   # kHz
      scaling_max_freq = 2000000;
      energy_performance_preference = "power";
    };
    charger = {
      governor = "performance";
      turbo = "auto";
      scaling_min_freq = 800000;
      scaling_max_freq = 3500000;
      energy_performance_preference = "performance";
    };
  };
};
```

For Intel CPUs, enable thermald for additional thermal management:

```nix
services.thermald.enable = true;
```

Surface tablets face **specific power management challenges** on Linux due to Connected Standby (s2idle) rather than traditional deep sleep (S3). This causes significant battery drain during suspend—up to 20% per 10 hours compared to minimal drain on Windows. Configure Surface-specific kernel parameters to optimize s2idle behavior:

```nix
boot.kernelParams = [
  "mem_sleep_default=s2idle"
  "i915.enable_dc=2"     # Intel display power saving
  "i915.enable_psr=1"    # Panel self-refresh
];

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
```

Expect battery life 25-40% worse than Windows on Surface devices, typically achieving 4-5 hours of active use versus 6-8 hours on Windows. The fundamental limitation stems from firmware-level Connected Standby implementation rather than Linux configuration, so optimize for active use rather than suspend efficiency.

Consider using hibernation for extended periods away from power:

```nix
# Configure hibernation if desired
boot.resumeDevice = "/dev/disk/by-label/nixos";
```

For long idle periods, shut down completely rather than suspending to conserve battery.

## Troubleshooting focuses on service logs and hardware validation

Common issues with NixOS + Phosh on Surface tablets cluster around service startup, hardware detection, and memory constraints. Start troubleshooting by checking systemd service status and logs:

```bash
# Phosh service status
journalctl -u phosh -b

# Display manager logs
cat ~/.local/state/tinydm.log

# Recent boot errors
journalctl -b -p err

# Surface kernel module loading
lsmod | grep surface
```

**Phosh crashes at launch** typically indicate missing GNOME service dependencies or incorrect user configuration. Verify that `gnome-keyring`, `evolution-data-server`, and `upower` are enabled, and ensure the specified user exists with proper group memberships including "networkmanager" and "video".

**Touchscreen not responding** suggests IPTS daemon issues or missing kernel modules. Confirm `microsoft-surface.ipts.enable = true` is set and the linux-surface kernel is active by checking `uname -r` for surface-specific version strings. Test touch input with `libinput debug-events` to verify events reach the input system.

**Type Cover not working at LUKS prompt** requires the Surface Aggregator Module drivers loaded in initrd as documented in the bootloader section. Without these modules in `boot.initrd.kernelModules`, the keyboard won't function before the main system loads.

**WiFi firmware errors on Surface Go** manifest as "Can't ping firmware" messages in dmesg. Enable the firmware replacement option: `hardware.microsoft-surface.firmware.surface-go-ath10k.replace = true;`

**ESP partition full** occurs when multiple kernel generations accumulate. Set `boot.loader.systemd-boot.configurationLimit = 10;` to automatically remove old boot entries, or manually clean with `sudo nix-collect-garbage --delete-older-than 30d`.

**Out of memory during rebuild** requires closing all applications, running garbage collection with `sudo nix-collect-garbage -d`, and rebuilding with `--max-jobs 1 --cores 1` flags. For persistent memory issues, set up remote building.

Enable debug logging for deeper investigation:

```bash
# Phosh debug output
export G_MESSAGES_DEBUG=all
export PHOSH_DEBUG=all
export PHOC_DEBUG=all

# Wayland protocol tracing
WAYLAND_DEBUG=1 phosh 2>&1 | tee wayland.log
```

Test configuration changes safely with `nixos-rebuild test` which activates without creating boot entries, allowing evaluation without permanent system modification.

## Version selection favors NixOS 24.11 stable with selective unstable packages

**Use NixOS 24.11 stable as the foundation** for production Surface tablet deployments. Released in November 2024 with support through June 2025, version 24.11 provides stable Phosh packages with well-tested hardware support modules. The stable release includes 8,141 new packages and 20,975 updated packages compared to 24.05, offering modern software without unstable channel instability.

NixOS unstable provides the latest Phosh versions (0.44.0+) and cutting-edge features but introduces potential breakage during updates. Consider unstable only for testing, development, or when specific bleeding-edge functionality is required that hasn't reached stable channels.

Implement a **mixed stable/unstable strategy** for optimal results—stable base system with selective unstable packages:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  
  outputs = { nixpkgs, nixpkgs-unstable, ... }: 
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
    in {
      nixosConfigurations.surface = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pkgs-unstable; };
        modules = [ ./configuration.nix ];
      };
    };
}
```

```nix
# configuration.nix
{ pkgs, pkgs-unstable, ... }: {
  environment.systemPackages = (with pkgs; [
    firefox         # Stable packages
    rnote
  ]) ++ (with pkgs-unstable; [
    phosh          # Unstable for latest features
    xournalpp      # If newer version needed
  ]);
}
```

This approach maintains system stability through the stable base while accessing newer application versions where beneficial. Test thoroughly before relying on mixed configurations since dependency conflicts can occur between stable and unstable packages.

Phosh availability in stable versus unstable shows minimal functional difference for basic tablet use, with unstable primarily offering newer mobile-specific features like improved gesture handling and text prediction. For Surface tablet daily driver use, stable provides sufficient functionality with better reliability.

## Backup strategy combines BorgBackup automation with Git configuration tracking

NixOS's declarative configuration model fundamentally changes backup requirements since **the entire system configuration reproduces from /etc/nixos files**. Focus backups on configuration files and stateful user data rather than system packages:

```nix
services.borgbackup.jobs."nixos-backup" = {
  paths = [
    "/etc/nixos"
    "/home"
    "/var/lib"
  ];
  
  exclude = [
    "/home/*/.cache"
    "/home/*/Downloads"
    "*/node_modules"
    "*/.venv"
  ];
  
  repo = "ssh://user@backup-server//backup/surface";
  
  encryption = {
    mode = "repokey-blake2";
    passCommand = "cat /root/borg-passphrase";
  };
  
  compression = "auto,zstd";
  startAt = "daily";
  
  prune.keep = {
    daily = 7;
    weekly = 4;
    monthly = 6;
  };
};
```

Store the encryption passphrase securely in `/root/borg-passphrase` with `chmod 600` permissions. Initialize the repository on first use:

```bash
sudo borg init --encryption=repokey-blake2 ssh://user@server//backup/surface
```

Verify backups complete successfully by checking systemd status:

```bash
# Check recent backup
sudo systemctl status borgbackup-job-nixos-backup

# View backup logs
journalctl -u borgbackup-job-nixos-backup
```

Restore specific files by mounting the backup repository:

```bash
mkdir ~/borg-mount
borg mount ssh://user@server//backup/surface::latest ~/borg-mount
cp -a ~/borg-mount/etc/nixos/configuration.nix /etc/nixos/
borg umount ~/borg-mount
```

**Track configuration in Git from installation**, providing version control independent of Borg backups:

```bash
cd /etc/nixos
git init
git add configuration.nix hardware-configuration.nix flake.nix flake.lock
git commit -m "Initial Surface tablet configuration"
git remote add origin git@github.com:user/nixos-surface-config.git
git push -u origin main
```

Git tracking enables rolling back to any historical configuration even after garbage collection removes old system generations. Each configuration change becomes a commit with explanatory message documenting the modification rationale.

Recovery from total system failure follows this process: boot from NixOS installer, partition and format storage, mount partitions, clone the Git repository to `/mnt/etc/nixos`, run `nixos-install`, and restore user data from Borg backup. The declarative configuration rebuilds the identical system state without manual package installation or configuration file editing.

NixOS's generation system provides **atomic rollback capability** as an additional safety layer. List available generations with `sudo nix-env --list-generations --profile /nix/var/nix/profiles/system` and switch to previous working configurations at boot through the systemd-boot menu or with `sudo nixos-rebuild switch --rollback`. This rollback mechanism operates independently from backups, providing immediate recovery from configuration mistakes.

Garbage collection removes old generations to reclaim disk space, so balance retention against storage constraints:

```bash
# Delete generations older than 30 days
sudo nix-env --delete-generations 30d --profile /nix/var/nix/profiles/system

# Run garbage collection
sudo nix-collect-garbage

# Aggressive cleanup (keeps only current generation)
sudo nix-collect-garbage -d
```

Test rollback procedures before problems occur by intentionally switching to an older generation, verifying functionality, and switching back. Familiarity with the rollback process prevents panic during actual issues.

## Looking ahead to production deployment and maintenance patterns

The convergence of NixOS's declarative configuration, linux-surface's hardware support, and Phosh's mobile interface creates a viable platform for Linux tablet computing despite current ecosystem immaturity. Surface tablets with 4GB RAM represent the minimum viable specification, with 8GB providing more comfortable operation margins. The primary constraint remains battery life due to firmware-level Connected Standby limitations rather than software optimization opportunities.

Production deployments should establish automated testing pipelines using `nixos-rebuild build-vm` to validate configuration changes in virtual machines before applying to physical hardware. This testing catches issues with memory constraints or service dependencies before they impact the production system. Consider maintaining separate Git branches for experimental changes and stable configurations, merging only after thorough testing.

The NixOS community continues improving Surface support through nixos-hardware contributions and linux-surface kernel integration. Monitor the GitHub repositories for both projects to track compatibility improvements for your specific Surface model. Phosh development follows a six-week release cycle with steady progress toward GTK4 migration and wlroots 0.18 support, though production stability remains more important than bleeding-edge features for tablet daily driver use.

Future enhancements to this setup might include investigating impermanence patterns with ephemeral root filesystems, exploring additional mobile-optimized applications from the libadwaita ecosystem, and optimizing suspend behavior through custom systemd service management. The fundamental architecture—NixOS stable, nixos-hardware modules, Phosh from nixpkgs—provides a solid foundation for incremental improvements while maintaining system stability and reproducibility.
