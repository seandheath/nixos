#!/usr/bin/env bash

set -euo pipefail

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
# Get devices, filter out loop devices and cd/dvd drives, output only the NAME
DEVICES=($(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}'))

# Check if any devices were found
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

# --- Final Confirmation ---
echo
echo -e "\e[1;31mYou have selected \e[5m${DEVICE}\e[25m\e[1;31m for installation."
echo "ALL DATA ON THIS DEVICE WILL BE PERMANENTLY DESTROYED."
echo -e "This is your final chance to back out.\e[0m"
read -p "To confirm, type 'ERASE' in all caps and press Enter: " CONFIRMATION

if [[ "$CONFIRMATION" != "ERASE" ]]; then
    echo "Confirmation failed. Aborting."
    exit 1
fi

# --- Partitioning and Formatting ---
echo "Wiping and partitioning ${DEVICE}..."
sudo sgdisk --zap-all "${DEVICE}"
sudo sgdisk -n 1:0:+512M -t 1:ef00 -c 1:boot "${DEVICE}"
sudo sgdisk -n 2:0:0 -t 2:8300 -c 2:root "${DEVICE}"

# Wait a moment for the kernel to recognize the new partitions
sleep 2

# Determine partition naming scheme (e.g., sda1 vs nvme0n1p1)
if [[ "$DEVICE_NAME" =~ "nvme" || "$DEVICE_NAME" =~ "mmcblk" ]]; then
    PART_PREFIX="p"
else
    PART_PREFIX=""
fi

BOOT_PART="${DEVICE}${PART_PREFIX}1"
ROOT_PART="${DEVICE}${PART_PREFIX}2"

echo "Formatting partitions..."
sudo mkfs.vfat -F 32 -n BOOT "${BOOT_PART}"
sudo mkfs.ext4 -F -L root "${ROOT_PART}"

# --- Mounting ---
echo "Mounting filesystems..."
sudo mount "${ROOT_PART}" /mnt
sudo mkdir -p /mnt/boot
sudo mount "${BOOT_PART}" /mnt/boot

# --- Generate NixOS Config (for hardware-configuration.nix) ---
echo "Generating initial NixOS configuration..."
sudo nixos-generate-config --root /mnt

echo "Device setup complete. Proceeding with custom installation..."
echo

# --- Host Selection ---
echo "Available hosts:"
# Assuming the script is run from the root of the repo
HOSTS_DIR="./hosts"
if [[ ! -d "$HOSTS_DIR" ]]; then
    echo "Error: 'hosts' directory not found. Make sure you are in the root of the nixos-config repo."
    exit 1
fi

# Using fzf if available, otherwise a simple select menu
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
# This assumes the script is run from the root of the git repo.
# We need to copy the whole repo, including the .git directory.
sudo cp -r . /mnt/home/sheath/nixos

# --- Copy/Overwrite Hardware Configuration ---
echo "Copying hardware configuration..."
HARDWARE_DEST="/mnt/home/sheath/nixos/hardware/${hostname}.nix"
# The hardware directory should exist in the repo, but let's be safe.
sudo mkdir -p "$(dirname "$HARDWARE_DEST")"
sudo cp /mnt/etc/nixos/hardware-configuration.nix "$HARDWARE_DEST"

echo "Hardware configuration copied to $HARDWARE_DEST"

# --- Run Installation ---
echo "Running nixos-install..."
sudo nixos-install --root /mnt --flake "/mnt/home/sheath/nixos#${hostname}"

echo "Installation finished. You will now be dropped into a shell in the new system."
echo ">>> Please run 'passwd sheath' to set your user password, then type 'exit' to continue. <<<"

sudo nixos-enter --root /mnt

echo "Configuration complete! You can now reboot."
