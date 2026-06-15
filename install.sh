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
            if [[ "${encrypt:-true}" == "true" ]]; then
                sudo cryptsetup open "$luks_part" cryptroot || true
                BTRFS_DEV="/dev/mapper/cryptroot"
            else
                BTRFS_DEV="$root_part"
            fi
            OPTS="compress=zstd,noatime,discard=async"
            sudo mount -o subvol=@root,$OPTS "$BTRFS_DEV" /mnt
            sudo mount -o subvol=@nix,$OPTS "$BTRFS_DEV" /mnt/nix
            sudo mount -o subvol=@home,$OPTS "$BTRFS_DEV" /mnt/home
            sudo mount -o subvol=@persist,$OPTS "$BTRFS_DEV" /mnt/persist
            sudo mount -o subvol=@log,$OPTS "$BTRFS_DEV" /mnt/var/log
            sudo mount -o subvol=@swap,noatime "$BTRFS_DEV" /mnt/swap
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
echo "  2) Impermanence (Btrfs + LUKS encryption)"
echo "  3) Impermanence (Btrfs, no encryption)"
read -p "Enter choice [1-3]: " INSTALL_MODE

case "$INSTALL_MODE" in
    1) USE_IMPERMANENCE=false; ENCRYPT=false ;;
    2) USE_IMPERMANENCE=true;  ENCRYPT=true ;;
    3) USE_IMPERMANENCE=true;  ENCRYPT=false ;;
    *)
        echo "Invalid selection. Aborting."
        exit 1
        ;;
esac

# --- Final Confirmation ---
echo
echo -e "\e[1;31mYou have selected \e[5m${DEVICE}\e[25m\e[1;31m for installation."
if [[ "$USE_IMPERMANENCE" == "true" && "$ENCRYPT" == "true" ]]; then
    echo "Mode: IMPERMANENCE (Btrfs + LUKS)"
elif [[ "$USE_IMPERMANENCE" == "true" ]]; then
    echo "Mode: IMPERMANENCE (Btrfs, no encryption)"
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
    if [[ "$ENCRYPT" == "true" ]]; then
        # --- LUKS Setup ---
        echo
        echo "Setting up LUKS encryption..."
        echo "You will be prompted to enter a passphrase for disk encryption."
        sudo cryptsetup luksFormat --type luks2 "${ROOT_PART}"
        sudo cryptsetup open "${ROOT_PART}" cryptroot
        BTRFS_DEV="/dev/mapper/cryptroot"
    else
        # No encryption: Btrfs directly on the partition.
        BTRFS_DEV="${ROOT_PART}"
    fi

    # --- Btrfs Setup ---
    echo "Creating Btrfs filesystem..."
    sudo mkfs.btrfs -f -L nixos "$BTRFS_DEV"

    echo "Creating Btrfs subvolumes..."
    sudo mount "$BTRFS_DEV" /mnt

    sudo btrfs subvolume create /mnt/@root
    sudo btrfs subvolume create /mnt/@nix
    sudo btrfs subvolume create /mnt/@home
    sudo btrfs subvolume create /mnt/@persist
    sudo btrfs subvolume create /mnt/@log
    sudo btrfs subvolume create /mnt/@swap

    # Create empty snapshot for (optional, future) impermanence rollback
    echo "Creating blank snapshot for impermanence rollback..."
    sudo btrfs subvolume snapshot -r /mnt/@root /mnt/@root-blank

    sudo umount /mnt

    # --- Mount Subvolumes ---
    echo "Mounting subvolumes..."
    OPTS="compress=zstd,noatime,discard=async"

    sudo mount -o subvol=@root,$OPTS "$BTRFS_DEV" /mnt
    sudo mkdir -p /mnt/{boot,nix,home,persist,var/log,swap}
    sudo mount -o subvol=@nix,$OPTS "$BTRFS_DEV" /mnt/nix
    sudo mount -o subvol=@home,$OPTS "$BTRFS_DEV" /mnt/home
    sudo mount -o subvol=@persist,$OPTS "$BTRFS_DEV" /mnt/persist
    sudo mount -o subvol=@log,$OPTS "$BTRFS_DEV" /mnt/var/log
    sudo mount -o subvol=@swap,noatime "$BTRFS_DEV" /mnt/swap
    sudo mount "${BOOT_PART}" /mnt/boot

    # Get UUIDs for hardware config
    EFI_UUID=$(sudo blkid -s UUID -o value "${BOOT_PART}")
    if [[ "$ENCRYPT" == "true" ]]; then
        LUKS_UUID=$(sudo blkid -s UUID -o value "${ROOT_PART}")
    else
        BTRFS_UUID=$(sudo blkid -s UUID -o value "${ROOT_PART}")
    fi
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

# --- Install sops age key ---
# sops-nix decrypts secrets at first activation using this key; without it,
# secret-backed services (acme, nextcloud, paperless) fail on first boot.
echo

# Destination depends on layout: impermanence keeps it on the persistent /persist
# subvol (root-owned system path, no user-home ownership issues); simple mode uses
# the home path. These must match `sops.age.keyFile` for the host.
if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    AGE_KEY_DEST="/mnt/persist/secrets/age-keys.txt"
else
    AGE_KEY_DEST="/mnt/home/sheath/.config/sops/age/keys.txt"
fi

# Decrypt $1 to stdout using whatever age implementation is available in the live env.
age_decrypt() {
    if command -v age >/dev/null 2>&1; then age -d "$1"
    elif command -v rage >/dev/null 2>&1; then rage -d "$1"
    else nix --extra-experimental-features 'nix-command flakes' run nixpkgs#age -- -d "$1"
    fi
}

if [[ -f secrets/age-key.enc ]]; then
    echo "Decrypting secrets/age-key.enc (enter its passphrase)..."
    sudo mkdir -p "$(dirname "$AGE_KEY_DEST")"
    if age_decrypt secrets/age-key.enc | sudo tee "$AGE_KEY_DEST" >/dev/null; then
        sudo chmod 600 "$AGE_KEY_DEST"
        echo "Age key installed at ${AGE_KEY_DEST#/mnt}"
    else
        sudo rm -f "$AGE_KEY_DEST"
        echo "ERROR: failed to decrypt secrets/age-key.enc. Secret-backed services will"
        echo "fail on first boot until you place the key at ${AGE_KEY_DEST#/mnt} manually."
    fi
else
    # Fallback: copy a plaintext key from a path the user provides.
    read -p "secrets/age-key.enc not found. Path to plaintext age key (or Enter to skip): " AGE_KEY_SRC
    if [[ -n "$AGE_KEY_SRC" && -f "$AGE_KEY_SRC" ]]; then
        sudo install -Dm600 "$AGE_KEY_SRC" "$AGE_KEY_DEST"
        echo "Age key installed at ${AGE_KEY_DEST#/mnt}"
    elif [[ -n "$AGE_KEY_SRC" ]]; then
        echo "Warning: '${AGE_KEY_SRC}' not found; skipping age key install."
    fi
fi

# --- Handle Hardware Configuration ---
HARDWARE_DEST="/mnt/home/sheath/nixos/hardware/${hostname}.nix"
sudo mkdir -p "$(dirname "$HARDWARE_DEST")"

if [[ "$USE_IMPERMANENCE" == "true" ]]; then
    # Generate hardware config with Btrfs mounts
    echo "Generating Btrfs hardware configuration..."

    # Get hardware modules from generated config
    AVAILABLE_MODULES=$(grep -oP 'boot\.initrd\.availableKernelModules\s*=\s*\[\K[^\]]+' /mnt/etc/nixos/hardware-configuration.nix || echo '"xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod"')
    KERNEL_MODULES=$(grep -oP 'boot\.kernelModules\s*=\s*\[\K[^\]]+' /mnt/etc/nixos/hardware-configuration.nix || echo '"kvm-intel"')

    # The btrfs device and optional LUKS block depend on the encryption choice.
    if [[ "$ENCRYPT" == "true" ]]; then
        BTRFS_DEVICE="/dev/mapper/cryptroot"
        LUKS_BLOCK="  # LUKS configuration
  boot.initrd.luks.devices.\"cryptroot\" = {
    device = \"/dev/disk/by-uuid/${LUKS_UUID}\";
    allowDiscards = true;
    bypassWorkqueues = true;
  };
"
    else
        BTRFS_DEVICE="/dev/disk/by-uuid/${BTRFS_UUID}"
        LUKS_BLOCK=""
    fi

    # --- Optional separate /data disk (existing, NOT reformatted) ---
    DATA_FS_BLOCK=""
    echo
    read -p "Configure a separate /data disk (preserve existing data)? [y/N]: " WANT_DATA
    if [[ "$WANT_DATA" =~ ^[Yy]$ ]]; then
        echo "Available block devices:"
        lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
        echo "(For a multi-device btrfs / RAID array, pick ANY one member -- all members"
        echo " share one filesystem UUID and the by-uuid mount assembles the whole array.)"
        read -p "Enter the existing data device/partition to mount as /data (e.g. sdb1): " DATA_NAME
        DATA_DEV="/dev/${DATA_NAME}"
        DATA_UUID=$(sudo blkid -s UUID -o value "$DATA_DEV" || true)
        DATA_TYPE=$(sudo blkid -s TYPE -o value "$DATA_DEV" || true)
        if [[ -z "$DATA_UUID" || -z "$DATA_TYPE" ]]; then
            echo "ERROR: could not read a filesystem on ${DATA_DEV}. Aborting."
            exit 1
        fi
        if [[ "$DATA_TYPE" == "btrfs" ]]; then
            DATA_OPTS='[ "noatime" "compress=zstd" ]'
            # Confirm the full array (multi-device btrfs members share this UUID).
            sudo btrfs device scan >/dev/null 2>&1 || true
            echo "btrfs filesystem for UUID ${DATA_UUID}:"
            sudo btrfs filesystem show "${DATA_UUID}" || true
            ndev=$(sudo btrfs filesystem show "${DATA_UUID}" 2>/dev/null | grep -c 'devid' || true)
            if [[ "${ndev:-1}" -gt 1 ]]; then
                echo "NOTE: multi-device btrfs (${ndev} devices). The by-uuid mount assembles the"
                echo "      whole array; ALL ${ndev} drives must be present at boot (RAID0 = no redundancy)."
            fi
        else
            DATA_OPTS='[ "noatime" ]'
        fi
        DATA_FS_BLOCK="
  # Existing data filesystem (preserved, not reformatted by the installer).
  # For a multi-device btrfs the shared UUID mounts the whole array.
  fileSystems.\"/data\" = {
    device = \"/dev/disk/by-uuid/${DATA_UUID}\";
    fsType = \"${DATA_TYPE}\";
    options = ${DATA_OPTS};
  };
"
        echo "Will mount UUID ${DATA_UUID} (${DATA_TYPE}) at /data."
    fi

    sudo tee "$HARDWARE_DEST" > /dev/null << EOF
# Hardware configuration for ${hostname}
# Generated by install.sh (Btrfs impermanence layout)
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

${LUKS_BLOCK}
  # Btrfs mount options
  fileSystems."/" = {
    device = "${BTRFS_DEVICE}";
    fsType = "btrfs";
    options = [ "subvol=@root" "compress=zstd" "noatime" "discard=async" ];
  };

  fileSystems."/nix" = {
    device = "${BTRFS_DEVICE}";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/home" = {
    device = "${BTRFS_DEVICE}";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "${BTRFS_DEVICE}";
    fsType = "btrfs";
    options = [ "subvol=@persist" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/var/log" = {
    device = "${BTRFS_DEVICE}";
    fsType = "btrfs";
    options = [ "subvol=@log" "compress=zstd" "noatime" "discard=async" ];
    neededForBoot = true;
  };

  fileSystems."/swap" = {
    device = "${BTRFS_DEVICE}";
    fsType = "btrfs";
    options = [ "subvol=@swap" "noatime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/${EFI_UUID}";
    fsType = "vfat";
    options = [ "fmask=0022" "dmask=0022" ];
  };
${DATA_FS_BLOCK}
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

    if [[ "$ENCRYPT" == "true" ]]; then
        # --- Declarative passwords + persisted host keys (LUKS/impermanence, sulphur-style) ---
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
    fi

    # Create swap file (both impermanence modes; referenced by the hardware config)
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
echo "encrypt=${ENCRYPT}" >> "$RESUME_FILE"
if [[ "$ENCRYPT" == "true" ]]; then
    echo "luks_part=${ROOT_PART}" >> "$RESUME_FILE"
fi
echo "stage=install" >> "$RESUME_FILE"

# --- Run Installation ---
echo "Running nixos-install..."
if sudo nixos-install --root /mnt --flake "/mnt/home/sheath/nixos#${hostname}"; then
    echo "stage=passwd" >> "$RESUME_FILE"

    if [[ "$USE_IMPERMANENCE" == "true" && "$ENCRYPT" == "true" ]]; then
        echo
        echo "Installation finished!"
        echo "Note: With LUKS impermanence, passwords are stored in /persist/secrets/"
        echo "The passwords have already been set during installation."
        echo
        echo "You can now reboot into your new system."
    else
        echo "Installation finished. You will now be dropped into a shell in the new system."
        echo ">>> Set passwords now: run 'passwd', 'passwd sheath', 'passwd user' as needed, then 'exit'. <<<"
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
