# NixOS Btrfs Impermanence Setup Guide

## Overview

This guide configures NixOS with Btrfs subvolumes and impermanence. The root filesystem (`/`) is wiped on every boot and restored to a pristine snapshot, while critical data persists in designated locations.

**Target Hardware**: ASUS ROG Zephyrus G16 (2025) with 4TB Samsung 990 NVMe SSD

**Key Features**:
- LUKS2 full disk encryption
- Btrfs with zstd compression
- Root filesystem wipe on boot (impermanence)
- Persistent `/home`, `/nix`, `/persist`, and `/var/log`
- Automatic snapshot-based rollback

---

## Partition Layout

Create the following partition scheme:

| Partition | Size | Type | Mount Point |
|-----------|------|------|-------------|
| `/dev/nvme0n1p1` | 1GB | EFI System (ef00) | `/boot` |
| `/dev/nvme0n1p2` | Remainder | Linux filesystem (8300) | LUKS → Btrfs |

---

## Btrfs Subvolume Layout

All subvolumes are top-level (created at the Btrfs root, not nested):

| Subvolume | Mount Point | Purpose |
|-----------|-------------|---------|
| `@root` | `/` | Root filesystem (wiped on boot) |
| `@nix` | `/nix` | Nix store (persistent, compressed) |
| `@home` | `/home` | User home directories (persistent) |
| `@persist` | `/persist` | System state that survives wipes |
| `@log` | `/var/log` | System logs (persistent) |
| `@swap` | `/swap` | Swap file location |
| `@root-blank` | — | Empty snapshot of `@root` for rollback |

---

## Installation Steps

### 1. Partition the Disk

```bash
# Wipe and partition
wipefs -a /dev/nvme0n1
sgdisk --zap-all /dev/nvme0n1
sgdisk --clear \
  --new=1:0:+1GiB --typecode=1:ef00 --change-name=1:EFI \
  --new=2:0:0 --typecode=2:8300 --change-name=2:cryptroot \
  /dev/nvme0n1
```

### 2. Setup LUKS Encryption

```bash
cryptsetup luksFormat --type luks2 /dev/nvme0n1p2
cryptsetup open /dev/nvme0n1p2 cryptroot
```

### 3. Create Filesystems

```bash
mkfs.fat -F 32 -n EFI /dev/nvme0n1p1
mkfs.btrfs -L nixos /dev/mapper/cryptroot
```

### 4. Create Btrfs Subvolumes

```bash
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@root
btrfs subvolume create /mnt/@nix
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@persist
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@swap

# Create empty snapshot for rollback
btrfs subvolume snapshot -r /mnt/@root /mnt/@root-blank

umount /mnt
```

### 5. Mount Subvolumes for Installation

```bash
# Mount options
OPTS="compress=zstd,noatime,discard=async"

# Mount root
mount -o subvol=@root,$OPTS /dev/mapper/cryptroot /mnt

# Create mount points
mkdir -p /mnt/{boot,nix,home,persist,var/log,swap}

# Mount remaining subvolumes
mount -o subvol=@nix,$OPTS /dev/mapper/cryptroot /mnt/nix
mount -o subvol=@home,$OPTS /dev/mapper/cryptroot /mnt/home
mount -o subvol=@persist,$OPTS /dev/mapper/cryptroot /mnt/persist
mount -o subvol=@log,$OPTS /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@swap,noatime /dev/mapper/cryptroot /mnt/swap

# Mount EFI
mount /dev/nvme0n1p1 /mnt/boot
```

### 6. Generate Hardware Configuration

```bash
nixos-generate-config --root /mnt
```

---

## NixOS Configuration

### Required Flake Inputs

Add these inputs to `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    
    impermanence.url = "github:nix-community/impermanence";
    
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  
  outputs = { self, nixpkgs, nixos-hardware, impermanence, ... }@inputs: {
    nixosConfigurations.zephyrus = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        ./hardware-configuration.nix
        ./impermanence.nix
        nixos-hardware.nixosModules.asus-zephyrus-gu605my
        impermanence.nixosModules.impermanence
      ];
    };
  };
}
```

### hardware-configuration.nix

Ensure these settings are present (adjust UUIDs to match your system):

```nix
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # LUKS configuration
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/YOUR-LUKS-UUID";
    allowDiscards = true;
    bypassWorkqueues = true;
  };

  # Filesystem mounts
  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@root" "compress=zstd" "noatime" "discard=async" ];
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/home" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@persist" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/var/log" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@log" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/swap" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@swap" "noatime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/YOUR-EFI-UUID";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # Swap file on Btrfs
  swapDevices = [{
    device = "/swap/swapfile";
    size = 32768;  # 32GB - adjust based on RAM for hibernation
  }];

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
```

### impermanence.nix

This module handles the root wipe and persistence configuration:

```nix
{ config, lib, pkgs, ... }:

{
  # Enable systemd in initrd (required for rollback service)
  boot.initrd.systemd.enable = true;

  # Rollback service - wipes root on every boot
  boot.initrd.systemd.services.rollback = {
    description = "Rollback Btrfs root subvolume to pristine state";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-cryptsetup@cryptroot.service" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /mnt
      mount -o subvol=/ /dev/mapper/cryptroot /mnt

      # Delete all subvolumes under @root (handles nested subvolumes)
      btrfs subvolume list -o /mnt/@root | cut -f9 -d' ' | while read subvolume; do
        echo "Deleting nested subvolume: /$subvolume"
        btrfs subvolume delete "/mnt/$subvolume"
      done

      # Delete the root subvolume
      echo "Deleting @root subvolume"
      btrfs subvolume delete /mnt/@root

      # Restore from blank snapshot
      echo "Restoring @root from @root-blank snapshot"
      btrfs subvolume snapshot /mnt/@root-blank /mnt/@root

      umount /mnt
    '';
  };

  # Impermanence configuration
  environment.persistence."/persist" = {
    hideMounts = true;
    
    # System directories to persist
    directories = [
      "/etc/nixos"                              # NixOS configuration
      "/etc/NetworkManager/system-connections"  # WiFi networks
      "/etc/ssh"                                # SSH host keys
      "/var/lib/bluetooth"                      # Bluetooth pairings
      "/var/lib/nixos"                          # NixOS state (user IDs, etc.)
      "/var/lib/systemd/coredump"               # Core dumps
      "/var/lib/systemd/timers"                 # Persistent timers
      "/var/lib/fwupd"                          # Firmware update state
      "/var/lib/power-profiles-daemon"          # Power profile state
      
      # ASUS-specific
      "/etc/asusd"                              # asusctl configuration
    ];
    
    # System files to persist
    files = [
      "/etc/machine-id"
      "/etc/adjtime"                            # Hardware clock adjustment
    ];
  };

  # Ensure /persist exists and has correct permissions
  systemd.tmpfiles.rules = [
    "d /persist 0755 root root -"
    "d /persist/etc 0755 root root -"
    "d /persist/var 0755 root root -"
    "d /persist/var/lib 0755 root root -"
  ];

  # Required for impermanence to work with users
  programs.fuse.userAllowOther = true;
  
  # IMPORTANT: Set passwords declaratively since /etc/shadow is wiped
  # Option 1: Use hashedPasswordFile pointing to /persist
  # Option 2: Set hashedPassword directly (less secure but simpler for initial setup)
  users.mutableUsers = false;
  
  # Example user configuration - CUSTOMIZE THIS
  users.users.sean = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    # Generate with: mkpasswd -m sha-512
    hashedPasswordFile = "/persist/secrets/sean-password";
    # OR use hashedPassword directly for initial setup:
    # hashedPassword = "$6$rounds=...";
  };

  # Root password
  users.users.root.hashedPasswordFile = "/persist/secrets/root-password";
}
```

### configuration.nix (Base System)

Core system configuration with ASUS ROG support:

```nix
{ config, lib, pkgs, ... }:

{
  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 20;

  # Use latest kernel for best hardware support
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Hostname
  networking.hostName = "zephyrus";

  # Networking
  networking.networkmanager.enable = true;

  # Timezone and locale
  time.timeZone = "America/New_York";  # Adjust for Maine
  i18n.defaultLocale = "en_US.UTF-8";

  # ASUS ROG services
  services.asusd = {
    enable = true;
    enableUserService = true;
  };
  
  services.supergfxd.enable = true;
  
  # Fix for supergfxctl GPU detection
  systemd.services.supergfxd.path = [ pkgs.pciutils ];

  # Power management
  services.power-profiles-daemon.enable = true;
  services.thermald.enable = true;

  # NVIDIA configuration (for hybrid graphics)
  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = true;  # Use open source kernel modules (recommended for RTX 50 series)
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };

  # Enable OpenGL
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # Btrfs maintenance
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };

  # Firmware updates
  services.fwupd.enable = true;

  # Enable sound with PipeWire
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Basic packages
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    curl
    htop
    btop
    pciutils
    usbutils
    lshw
    btrfs-progs
    asusctl
    supergfxctl
  ];

  # Enable SSH (optional, for remote management)
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
    hostKeys = [
      { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
      { path = "/persist/etc/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
    ];
  };

  # Firewall
  networking.firewall.enable = true;

  system.stateVersion = "24.11";
}
```

---

## Post-Installation Setup

### 1. Create Password Files

After first boot, create password files in `/persist/secrets/`:

```bash
sudo mkdir -p /persist/secrets
sudo chmod 700 /persist/secrets

# Generate and store password hashes
echo "YOUR_HASHED_PASSWORD" | sudo tee /persist/secrets/sean-password
echo "YOUR_ROOT_HASHED_PASSWORD" | sudo tee /persist/secrets/root-password

sudo chmod 600 /persist/secrets/*
```

Generate password hashes with:
```bash
mkpasswd -m sha-512
```

### 2. Initialize SSH Host Keys

```bash
sudo mkdir -p /persist/etc/ssh
sudo ssh-keygen -t ed25519 -f /persist/etc/ssh/ssh_host_ed25519_key -N ""
sudo ssh-keygen -t rsa -b 4096 -f /persist/etc/ssh/ssh_host_rsa_key -N ""
```

### 3. Copy NixOS Configuration to Persist

```bash
sudo cp -r /etc/nixos /persist/etc/
```

---

## Detecting Impermanence Gaps

After running the system for a while, find files that were created but will be lost on reboot:

```bash
#!/usr/bin/env bash
# Run this script to find files that need to be persisted

# Mount the actual root subvolume
sudo mkdir -p /mnt/btrfs-root
sudo mount -o subvol=/ /dev/mapper/cryptroot /mnt/btrfs-root

# Compare current root with blank snapshot
sudo btrfs subvolume find-new /mnt/btrfs-root/@root-blank 9999999 > /tmp/blank-files
sudo btrfs subvolume find-new /mnt/btrfs-root/@root 9999999 > /tmp/current-files

# Show differences
diff /tmp/blank-files /tmp/current-files

sudo umount /mnt/btrfs-root
```

Alternative approach using `impermanence`'s built-in detection:
```bash
# List files in root that aren't bind-mounted from /persist
sudo find / -xdev -type f 2>/dev/null | head -100
```

---

## Adding New Persistent Paths

To persist additional directories or files, add them to `impermanence.nix`:

```nix
environment.persistence."/persist" = {
  directories = [
    # Add new directories here
    "/var/lib/docker"           # If using Docker
    "/var/lib/libvirt"          # If using libvirt/QEMU
    "/var/lib/tailscale"        # If using Tailscale
  ];
  
  files = [
    # Add new files here
  ];
};
```

---

## Snapshot Management (Optional)

For manual snapshots before risky operations:

```nix
# Add to configuration.nix
services.btrbk.instances.manual = {
  onCalendar = "";  # No automatic schedule
  settings = {
    snapshot_preserve_min = "7d";
    snapshot_preserve = "7d 4w";
    volume."/" = {
      subvolume = {
        "@home" = {};
        "@persist" = {};
      };
      snapshot_dir = "@snapshots";
    };
  };
};
```

Create snapshots manually:
```bash
sudo btrbk -c /etc/btrbk/manual.conf snapshot
```

---

## Troubleshooting

### Boot Fails After Rollback Service

If the system won't boot, use a live USB to manually restore:

```bash
cryptsetup open /dev/nvme0n1p2 cryptroot
mount -o subvol=/ /dev/mapper/cryptroot /mnt

# Check subvolume state
btrfs subvolume list /mnt

# Manually restore if needed
btrfs subvolume delete /mnt/@root
btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
```

### NetworkManager Connections Not Persisting

Ensure the path is correct and `neededForBoot` is set on `/persist`:

```nix
environment.persistence."/persist".directories = [
  "/etc/NetworkManager/system-connections"
];
```

### User Can't Login After Reboot

This usually means:
1. Password file doesn't exist in `/persist/secrets/`
2. `users.mutableUsers = false` is set but no password is configured
3. The persist mount isn't happening early enough (`neededForBoot = true`)

---

## Directory Structure Reference

After setup, your system should have:

```
/
├── boot/                    # EFI partition (persistent)
├── home/                    # @home subvolume (persistent)
│   └── sean/
├── nix/                     # @nix subvolume (persistent)
├── persist/                 # @persist subvolume (persistent)
│   ├── etc/
│   │   ├── nixos/
│   │   ├── ssh/
│   │   ├── NetworkManager/
│   │   └── asusd/
│   ├── secrets/
│   │   ├── sean-password
│   │   └── root-password
│   └── var/lib/
├── swap/                    # @swap subvolume
│   └── swapfile
├── var/
│   └── log/                 # @log subvolume (persistent)
└── [everything else]        # Wiped on reboot
```

---

## Security Notes

1. **Password files**: Store in `/persist/secrets/` with `600` permissions
2. **SSH keys**: User SSH keys should be in `/home/user/.ssh/` (already persistent)
3. **GPG keys**: Already persistent in `/home/user/.gnupg/`
4. **Secrets management**: Consider using `agenix` or `sops-nix` for encrypted secrets in your config repo

---

## Next Steps After Stabilization

Once the system is stable, consider:

1. **Home Manager with impermanence**: Make parts of your home directory impermanent too
2. **Automated snapshots**: Configure btrbk for automatic pre-rebuild snapshots
3. **Disko**: Migrate to declarative disk partitioning for reproducible installs
4. **Secrets management**: Implement agenix or sops-nix for encrypted secrets in git
