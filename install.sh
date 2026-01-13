#!/usr/bin/env bash

set -euo pipefail

# --- Resume Functionality ---
RESUME_FILE="/tmp/nixos-install-resume"

if [[ "${1:-}" == "--resume" ]]; then
    if [[ ! -f "$RESUME_FILE" ]]; then
        echo "No resume state found. Run the script normally to start fresh."
        exit 1
    fi

    echo "Resuming previous installation..."
    source "$RESUME_FILE"

    # Check if partitions are still mounted
    if ! mountpoint -q /mnt; then
        echo "Mounting filesystems..."
        if [[ "$use_impermanence" == "true" ]]; then
            sudo cryptsetup open "$luks_part" cryptroot || true
            OPTS="compress=zstd,noatime,discard=async"
            sudo mount -o subvol=@root,$OPTS /dev/mapper/cryptroot /mnt
            sudo mount -o subvol=@nix,$OPTS /dev/mapper/cryptroot /mnt/nix
            sudo mount -o subvol=@home,$OPTS /dev/mapper/cryptroot /mnt/home
            sudo mount -o subvol=@persist,$OPTS /dev/mapper/cryptroot /mnt/persist
            sudo mount -o subvol=@log,$OPTS /dev/mapper/cryptroot /mnt/var/log
            sudo mount -o subvol=@swap,noatime /dev/mapper/cryptroot /mnt/swap
            sudo mount "$boot_part" /mnt/boot
        else
            sudo mount "$root_part" /mnt
            sudo mount "$boot_part" /mnt/boot
        fi
    fi

    case "$stage" in
        "install")
            echo "Resuming nixos-install..."
            if sudo nixos-install --root /mnt --flake "/mnt/home/sheath/nixos#${hostname}"; then
                echo "stage=passwd" >> "$RESUME_FILE"
                echo "Installation finished. You will now be dropped into a shell in the new system."
                echo ">>> Please run 'passwd sheath' to set your user password, then type 'exit' to continue. <<<"
                sudo nixos-enter --root /mnt
                rm -f "$RESUME_FILE"
                echo "Configuration complete! You can now reboot."
            else
                echo "Installation failed again. Check the logs and try again."
                exit 1
            fi
            ;;
        "passwd")
            echo "Installation was successful. Entering system to set password..."
            echo ">>> Please run 'passwd sheath' to set your user password, then type 'exit' to continue. <<<"
            sudo nixos-enter --root /mnt
            rm -f "$RESUME_FILE"
            echo "Configuration complete! You can now reboot."
            ;;
        *)
            echo "Unknown resume stage: $stage"
            exit 1
            ;;
    esac
    exit 0
fi

# --- WARNING ---
echo -e "\n\n\e[1;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!! DANGER: THIS SCRIPT WILL ERASE ALL DATA ON A DISK !!!"
echo -e "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\e[0m\n"
echo "This script will automate the entire NixOS installation, including partitioning."
echo "Please back up any important data before proceeding."
echo
read -p "Press Enter to continue if you understand the risk..."

# --- Device Selection ---
echo
echo "Please select the device to install on."
DEVICES=($(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}'))

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "No suitable disk devices found. Aborting."
    exit 1
fi

PS3="Enter the number of the device: "
select DEVICE_NAME in "${DEVICES[@]}"; do
    if [[ -n "$DEVICE_NAME" ]]; then
        echo "You selected ${DEVICE_NAME}."
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

DEVICE="/dev/${DEVICE_NAME}"

# --- Installation Mode Selection ---
echo
echo "Select installation mode:"
echo "  1) Simple (ext4, no encryption)"
echo "  2) Impermanence (Btrfs + LUKS encryption, root wiped on boot)"
read -p "Enter choice [1-2]: " INSTALL_MODE

case "$INSTALL_MODE" in
    1) USE_IMPERMANENCE=false ;;
    2) USE_IMPERMANENCE=true ;;
    *)
        echo "Invalid selection. Aborting."
        exit 1
        ;;
esac

# --- Final Confirmation ---
echo
echo -e "\e[1;31mYou have selected \e[5m${DEVICE}\e[25m\e[1;31m for installation."
if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    echo "Mode: IMPERMANENCE (Btrfs + LUKS, root wiped on boot)"
else
    echo "Mode: SIMPLE (ext4, no encryption)"
fi
echo "ALL DATA ON THIS DEVICE WILL BE PERMANENTLY DESTROYED."
echo -e "This is your final chance to back out.\e[0m"
read -p "To confirm, type 'ERASE' in all caps and press Enter: " CONFIRMATION

if [[ "$CONFIRMATION" != "ERASE" ]]; then
    echo "Confirmation failed. Aborting."
    exit 1
fi

# --- Partitioning ---
echo "Wiping and partitioning ${DEVICE}..."
sudo sgdisk --zap-all "${DEVICE}"

if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    # 1GB boot, rest for LUKS
    sudo sgdisk -n 1:0:+1GiB -t 1:ef00 -c 1:EFI "${DEVICE}"
    sudo sgdisk -n 2:0:0 -t 2:8300 -c 2:cryptroot "${DEVICE}"
else
    # 512MB boot, rest for root
    sudo sgdisk -n 1:0:+512M -t 1:ef00 -c 1:boot "${DEVICE}"
    sudo sgdisk -n 2:0:0 -t 2:8300 -c 2:root "${DEVICE}"
fi

sleep 2

# Determine partition naming scheme
if [[ "$DEVICE_NAME" =~ "nvme" || "$DEVICE_NAME" =~ "mmcblk" ]]; then
    PART_PREFIX="p"
else
    PART_PREFIX=""
fi

BOOT_PART="${DEVICE}${PART_PREFIX}1"
ROOT_PART="${DEVICE}${PART_PREFIX}2"

# --- Formatting ---
echo "Formatting boot partition..."
sudo mkfs.vfat -F 32 -n EFI "${BOOT_PART}"

if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    # --- LUKS Setup ---
    echo
    echo "Setting up LUKS encryption..."
    echo "You will be prompted to enter a passphrase for disk encryption."
    sudo cryptsetup luksFormat --type luks2 "${ROOT_PART}"
    sudo cryptsetup open "${ROOT_PART}" cryptroot

    # --- Btrfs Setup ---
    echo "Creating Btrfs filesystem..."
    sudo mkfs.btrfs -L nixos /dev/mapper/cryptroot

    echo "Creating Btrfs subvolumes..."
    sudo mount /dev/mapper/cryptroot /mnt

    sudo btrfs subvolume create /mnt/@root
    sudo btrfs subvolume create /mnt/@nix
    sudo btrfs subvolume create /mnt/@home
    sudo btrfs subvolume create /mnt/@persist
    sudo btrfs subvolume create /mnt/@log
    sudo btrfs subvolume create /mnt/@swap

    # Create empty snapshot for rollback
    echo "Creating blank snapshot for impermanence rollback..."
    sudo btrfs subvolume snapshot -r /mnt/@root /mnt/@root-blank

    sudo umount /mnt

    # --- Mount Subvolumes ---
    echo "Mounting subvolumes..."
    OPTS="compress=zstd,noatime,discard=async"

    sudo mount -o subvol=@root,$OPTS /dev/mapper/cryptroot /mnt
    sudo mkdir -p /mnt/{boot,nix,home,persist,var/log,swap}
    sudo mount -o subvol=@nix,$OPTS /dev/mapper/cryptroot /mnt/nix
    sudo mount -o subvol=@home,$OPTS /dev/mapper/cryptroot /mnt/home
    sudo mount -o subvol=@persist,$OPTS /dev/mapper/cryptroot /mnt/persist
    sudo mount -o subvol=@log,$OPTS /dev/mapper/cryptroot /mnt/var/log
    sudo mount -o subvol=@swap,noatime /dev/mapper/cryptroot /mnt/swap
    sudo mount "${BOOT_PART}" /mnt/boot

    # Get UUIDs for hardware config
    LUKS_UUID=$(sudo blkid -s UUID -o value "${ROOT_PART}")
    EFI_UUID=$(sudo blkid -s UUID -o value "${BOOT_PART}")
else
    # --- Simple ext4 Setup ---
    echo "Formatting root partition..."
    sudo mkfs.ext4 -F -L root "${ROOT_PART}"

    echo "Mounting filesystems..."
    sudo mount "${ROOT_PART}" /mnt
    sudo mkdir -p /mnt/boot
    sudo mount "${BOOT_PART}" /mnt/boot
fi

# --- Generate NixOS Config ---
echo "Generating initial NixOS configuration..."
sudo nixos-generate-config --root /mnt

echo "Device setup complete. Proceeding with custom installation..."
echo

# --- Host Selection ---
echo "Available hosts:"
HOSTS_DIR="./hosts"
if [[ ! -d "$HOSTS_DIR" ]]; then
    echo "Error: 'hosts' directory not found. Make sure you are in the root of the nixos-config repo."
    exit 1
fi

if command -v fzf &> /dev/null; then
    hostname=$(ls -1 "$HOSTS_DIR" | sed 's/\.nix$//' | fzf --prompt="Select a host to install: ")
else
    select host in $(ls -1 "$HOSTS_DIR" | sed 's/\.nix$//'); do
        hostname=$host
        break
    done
fi

if [[ -z "$hostname" ]]; then
    echo "No host selected. Aborting."
    exit 1
fi

echo "Selected host: $hostname"

# --- Copy Configuration ---
echo "Copying configuration to /mnt/home/sheath/nixos..."
sudo mkdir -p /mnt/home/sheath
sudo cp -r . /mnt/home/sheath/nixos

# --- Handle Hardware Configuration ---
HARDWARE_DEST="/mnt/home/sheath/nixos/hardware/${hostname}.nix"
sudo mkdir -p "$(dirname "$HARDWARE_DEST")"

if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    # Generate hardware config with Btrfs mounts
    echo "Generating Btrfs hardware configuration..."

    # Get hardware modules from generated config
    AVAILABLE_MODULES=$(grep -oP 'boot\.initrd\.availableKernelModules\s*=\s*\[\K[^\]]+' /mnt/etc/nixos/hardware-configuration.nix || echo '"xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod"')
    KERNEL_MODULES=$(grep -oP 'boot\.kernelModules\s*=\s*\[\K[^\]]+' /mnt/etc/nixos/hardware-configuration.nix || echo '"kvm-intel"')

    sudo tee "$HARDWARE_DEST" > /dev/null << EOF
# Hardware configuration for ${hostname}
# Generated by install.sh with impermanence support
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ ${AVAILABLE_MODULES} ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ${KERNEL_MODULES} ];
  boot.extraModulePackages = [ ];

  # Kernel parameters
  boot.kernelParams = [
    "nvme_core.default_ps_max_latency_us=0"
  ];

  # LUKS configuration
  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/${LUKS_UUID}";
    allowDiscards = true;
    bypassWorkqueues = true;
  };

  # Btrfs mount options
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
    device = "/dev/disk/by-uuid/${EFI_UUID}";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };

  # Swap file on Btrfs (32GB for hibernation support)
  swapDevices = [{
    device = "/swap/swapfile";
    size = 32768;
  }];

  # Optimize I/O scheduler for NVMe
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
  '';

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
EOF
    echo "Hardware configuration generated at $HARDWARE_DEST"

    # --- Create persist directories and password files ---
    echo "Setting up /persist structure..."
    sudo mkdir -p /mnt/persist/secrets
    sudo chmod 700 /mnt/persist/secrets
    sudo mkdir -p /mnt/persist/etc/nixos
    sudo mkdir -p /mnt/persist/etc/ssh
    sudo mkdir -p /mnt/persist/etc/NetworkManager/system-connections
    sudo mkdir -p /mnt/persist/var/lib/nixos
    sudo mkdir -p /mnt/persist/var/lib/bluetooth
    sudo mkdir -p /mnt/persist/var/lib/systemd/coredump
    sudo mkdir -p /mnt/persist/var/lib/systemd/timers

    # Generate SSH host keys
    echo "Generating SSH host keys..."
    sudo ssh-keygen -t ed25519 -f /mnt/persist/etc/ssh/ssh_host_ed25519_key -N ""
    sudo ssh-keygen -t rsa -b 4096 -f /mnt/persist/etc/ssh/ssh_host_rsa_key -N ""

    # Prompt for password
    echo
    echo "Creating user password hash for impermanence..."
    echo "Enter password for user 'sheath':"
    SHEATH_HASH=$(mkpasswd -m sha-512)
    echo "$SHEATH_HASH" | sudo tee /mnt/persist/secrets/sheath-password > /dev/null
    sudo chmod 600 /mnt/persist/secrets/sheath-password

    echo "Enter password for root (or press Enter to use same as sheath):"
    read -s ROOT_PASS
    if [[ -z "$ROOT_PASS" ]]; then
        echo "$SHEATH_HASH" | sudo tee /mnt/persist/secrets/root-password > /dev/null
    else
        ROOT_HASH=$(echo "$ROOT_PASS" | mkpasswd -m sha-512 --stdin)
        echo "$ROOT_HASH" | sudo tee /mnt/persist/secrets/root-password > /dev/null
    fi
    sudo chmod 600 /mnt/persist/secrets/root-password

    # Create swap file
    echo "Creating swap file (this may take a while)..."
    sudo btrfs filesystem mkswapfile --size 32G /mnt/swap/swapfile
else
    # Simple mode - just copy the generated hardware config
    sudo cp /mnt/etc/nixos/hardware-configuration.nix "$HARDWARE_DEST"
    echo "Hardware configuration copied to $HARDWARE_DEST"
fi

# --- Create Resume State File ---
RESUME_FILE="/tmp/nixos-install-resume"
echo "device=${DEVICE}" > "$RESUME_FILE"
echo "hostname=${hostname}" >> "$RESUME_FILE"
echo "boot_part=${BOOT_PART}" >> "$RESUME_FILE"
echo "root_part=${ROOT_PART}" >> "$RESUME_FILE"
echo "use_impermanence=${USE_IMPERMANENCE}" >> "$RESUME_FILE"
if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    echo "luks_part=${ROOT_PART}" >> "$RESUME_FILE"
fi
echo "stage=install" >> "$RESUME_FILE"

# --- Run Installation ---
echo "Running nixos-install..."
if sudo nixos-install --root /mnt --flake "/mnt/home/sheath/nixos#${hostname}"; then
    echo "stage=passwd" >> "$RESUME_FILE"

    if [[ "$USE_IMPERMANENCE" == "true" ]]; then
        echo
        echo "Installation finished!"
        echo "Note: With impermanence, passwords are stored in /persist/secrets/"
        echo "The passwords have already been set during installation."
        echo
        echo "You can now reboot into your new system."
    else
        echo "Installation finished. You will now be dropped into a shell in the new system."
        echo ">>> Please run 'passwd sheath' to set your user password, then type 'exit' to continue. <<<"
        sudo nixos-enter --root /mnt
    fi

    rm -f "$RESUME_FILE"
    echo "Configuration complete! You can now reboot."
else
    echo
    echo -e "\e[1;31mNixOS installation failed!\e[0m"
    echo "Resume state saved to $RESUME_FILE"
    echo "You can resume the installation by running:"
    echo "  $0 --resume"
    exit 1
fi
