#!/usr/bin/env bash
# Launch a QEMU machine with two blank disks to exercise the installer by hand.
#
# checks.disko-vm covers the disk half automatically. This covers what it cannot: the
# TUI, the non-disk phases, and resuming across a reboot of the live ISO.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/installer-vm}"
ISO="${ISO:-}"
MEM="${MEM:-8G}"
CPUS="${CPUS:-4}"
SYS_SIZE="${SYS_SIZE:-60G}"
HOME_SIZE="${HOME_SIZE:-40G}"

usage() {
    cat <<EOF
usage: ISO=/path/to/nixos.iso $0 [--fresh]

  --fresh   recreate the virtual disks, discarding any previous install

env: WORK=$WORK MEM=$MEM CPUS=$CPUS SYS_SIZE=$SYS_SIZE HOME_SIZE=$HOME_SIZE

Without ISO, downloads nothing and fails: point it at a NixOS minimal ISO.

Inside the guest:
    sudo -i
    nix --extra-experimental-features 'nix-command flakes' \\
        run github:seandheath/nixos#installer

The serials below are what make /dev/disk/by-id/ links appear, so the installer's
by-id selection is genuinely exercised rather than bypassed.
EOF
}

fresh=false
for arg in "$@"; do
    case "$arg" in
        --fresh) fresh=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

[[ -n "$ISO" ]] || { usage; exit 1; }
[[ -f "$ISO" ]] || { echo "no such ISO: $ISO" >&2; exit 1; }

mkdir -p "$WORK"
if [[ "$fresh" == true ]]; then
    rm -f "$WORK"/sys.qcow2 "$WORK"/home.qcow2 "$WORK"/vars.fd
fi
[[ -f "$WORK/sys.qcow2" ]]  || qemu-img create -f qcow2 "$WORK/sys.qcow2"  "$SYS_SIZE"
[[ -f "$WORK/home.qcow2" ]] || qemu-img create -f qcow2 "$WORK/home.qcow2" "$HOME_SIZE"

# UEFI: the fleet is systemd-boot only, and the installer refuses a BIOS boot.
OVMF_CODE=$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths nixpkgs#OVMF.fd)/FV/OVMF_CODE.fd
OVMF_VARS=$(nix --extra-experimental-features 'nix-command flakes' \
    build --no-link --print-out-paths nixpkgs#OVMF.fd)/FV/OVMF_VARS.fd
[[ -f "$WORK/vars.fd" ]] || install -m600 "$OVMF_VARS" "$WORK/vars.fd"

accel=tcg
[[ -w /dev/kvm ]] && accel=kvm

echo "booting: $ISO  (accel=$accel, disks in $WORK)"
exec qemu-system-x86_64 \
    -machine q35,accel="$accel" \
    -m "$MEM" -smp "$CPUS" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -drive file="$WORK/sys.qcow2",if=none,id=sys \
    -device nvme,drive=sys,serial=INSTALLERSYS0001 \
    -drive file="$WORK/home.qcow2",if=none,id=home \
    -device nvme,drive=home,serial=INSTALLERHOME0001 \
    -cdrom "$ISO" \
    -boot menu=on \
    -nic user,model=virtio-net-pci \
    -display gtk

# Test matrix, in order:
#   1. two-disk encrypted install; reboot; confirm ONE passphrase prompt opens both.
#   2. kill QEMU during nixos-install, relaunch WITHOUT --fresh, press m then r:
#      the earlier phases must already show done.
#   3. run to completion a second time: it must be safe and change nothing.
echo "see $HERE/vm-install.sh for the test matrix"
