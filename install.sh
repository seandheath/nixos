#!/usr/bin/env bash

set -euo pipefail

# --- Verification ---
echo "Verifying installation prerequisites..."

if ! mountpoint -q /mnt; then
  echo "Error: /mnt is not a mountpoint. Please partition and mount your drives first."
  exit 1
fi

if ! mountpoint -q /mnt/boot; then
  echo "Error: /mnt/boot is not a mountpoint. Please mount your boot partition."
  exit 1
fi

if [[ ! -f /mnt/etc/nixos/hardware-configuration.nix ]]; then
  echo "Error: /mnt/etc/nixos/hardware-configuration.nix not found."
  echo "Please run 'nixos-generate-config --root /mnt' first."
  exit 1
fi

echo "Prerequisites verified."

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
# Assuming the script is run from the repo's root directory
# `.` is the current directory (the repo)
sudo cp -r . /mnt/home/sheath/nixos

# --- Copy Hardware Configuration ---
echo "Copying hardware configuration..."
HARDWARE_DEST="/mnt/home/sheath/nixos/hardware/${hostname}.nix"
sudo mkdir -p "$(dirname "$HARDWARE_DEST")"
sudo cp /mnt/etc/nixos/hardware-configuration.nix "$HARDWARE_DEST"

echo "Hardware configuration copied to $HARDWARE_DEST"

# --- Run Installation ---
echo "Running nixos-install..."
sudo nixos-install --root /mnt --flake "/mnt/home/sheath/nixos#${hostname}"

echo "Installation complete! You can now reboot."
