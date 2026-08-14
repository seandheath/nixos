#!/usr/bin/env bash
# NixOS installer: choose a host and its disks, let disko partition, then nixos-install.

# fact_* are assigned by the facts file that load_facts generates and sources.
# shellcheck disable=SC2154

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET=/mnt
DEST="$TARGET/home/sheath/nixos"
SCRATCH=/tmp/nixos-install
ANSWERS="$SCRATCH/answers"
# Read only by `disko --mode format`; see the passwordFile option in modules/disk-layout.nix.
LUKS_KEY="$SCRATCH/luks.key"
# On @persist deliberately. /tmp dies with the live ISO and a tmpfs root evaporates on
# reboot, which is exactly when a resume matters most.
STATE_DIR="$TARGET/persist/nixos-install"
STATE="$STATE_DIR/state"

NIX=(nix --extra-experimental-features "nix-command flakes")

PHASES=(preflight select partition hardware config secrets install finalize)

log()  { printf '\n\e[1;34m==>\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33mwarning:\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: ./install.sh [--resume] [--from PHASE] [--host HOST]

  --resume      continue an interrupted install, re-running from the first
                phase that is not already done on the target
  --from PHASE  force a restart at PHASE
  --host HOST   skip the host picker

phases: preflight select partition hardware config secrets install finalize

Only `partition` is destructive. Everything before it can be re-run freely;
everything after it is idempotent.
EOF
}

# --- state -----------------------------------------------------------------------------

mark_done() {
    sudo mkdir -p "$STATE_DIR"
    printf '%s\n' "$1" | sudo tee -a "$STATE" >/dev/null
}

is_marked() { [[ -f "$STATE" ]] && sudo grep -qx "$1" "$STATE"; }

# --- facts -----------------------------------------------------------------------------
#
# Ask the host's own configuration rather than inferring from the disk layout. The old
# script guessed the age-key path from "is this impermanence?", which was wrong for every
# host that persists /persist without overriding sops.age.keyFile.
load_facts() {
    local factfile="$SCRATCH/facts" applyexpr
    mkdir -p "$SCRATCH"
    # Emitted as shell assignments and sourced: one full evaluation of the host, and no
    # dependency on jq or python, neither of which the installer ISO carries. Inlined
    # rather than imported from a file, which pure evaluation mode forbids.
    applyexpr=$(cat <<'NIX'
c:
let
  bool = b: if b then "true" else "false";
  persistSsh =
    let stores = builtins.attrValues (c.environment.persistence or { });
    in builtins.any
         (s: builtins.any (d: (d.directory or d) == "/etc/ssh") (s.directories or [ ]))
         stores;
in ''
  fact_ageKeyFile=${c.sops.age.keyFile}
  fact_sopsFile=${builtins.baseNameOf (toString c.sops.defaultSopsFile)}
  fact_rootPassword=${c.fleet.accounts.rootPassword}
  fact_mutableUsers=${bool c.users.mutableUsers}
  fact_diskEnabled=${bool c.fleet.disk.enable}
  fact_persistSsh=${bool persistSsh}
''
NIX
)
    log "Reading ${hostname}'s configuration"
    "${NIX[@]}" eval --raw ".#nixosConfigurations.${hostname}.config" \
        --apply "$applyexpr" > "$factfile" \
        || die "could not evaluate ${hostname}"
    # shellcheck disable=SC1090
    source "$factfile"
    [[ -n "${fact_ageKeyFile:-}" ]] || die "could not read sops.age.keyFile for ${hostname}"
}

# --- disks -----------------------------------------------------------------------------

# Prefer a model+serial link; wwn-/eui. links are stable too but say nothing to a human
# reading the committed disk-config months later.
by_id_for() {
    local dev="$1" link best=""
    for link in /dev/disk/by-id/*; do
        [[ -e "$link" ]] || continue
        [[ "$(readlink -f "$link")" == "$dev" ]] || continue
        case "$(basename "$link")" in
            wwn-*|nvme-eui.*) [[ -n "$best" ]] || best="$link" ;;
            *) best="$link"; break ;;
        esac
    done
    [[ -n "$best" ]] || die "no /dev/disk/by-id link for $dev; refusing to write an unstable path"
    printf '%s' "$best"
}

show_disks() {
    printf '\n'
    lsblk -dn -o NAME,SIZE,MODEL,SERIAL -e 7,11 | nl -w2 -s') '
}

# Echoes the chosen /dev/<name>, or nothing if the user declined an optional role.
pick_disk() {
    local prompt="$1" optional="${2:-false}" names choice
    mapfile -t names < <(lsblk -dn -o NAME -e 7,11)
    while true; do
        show_disks
        if [[ "$optional" == "true" ]]; then
            read -rp "$prompt (number, or Enter to skip): " choice
            [[ -n "$choice" ]] || return 0
        else
            read -rp "$prompt (number): " choice
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            printf '/dev/%s' "${names[choice-1]}"
            return 0
        fi
        echo "Invalid selection."
    done
}

ask_yn() {
    local prompt="$1" default="${2:-y}" reply
    read -rp "$prompt [$( [[ $default == y ]] && echo 'Y/n' || echo 'y/N' )]: " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

# --- phases ----------------------------------------------------------------------------

phase_preflight() {
    [[ -f "$REPO/flake.nix" ]] || die "run this from the repository root"
    [[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode; this fleet is systemd-boot only"
    command -v sudo >/dev/null || die "sudo is missing"
    mkdir -p "$SCRATCH"
    chmod 700 "$SCRATCH"

    DISKO_REV=$("${NIX[@]}" eval --raw --impure \
        --expr "(builtins.fromJSON (builtins.readFile $REPO/flake.lock)).nodes.disko.locked.rev") \
        || die "could not read the locked disko revision from flake.lock"
    log "Building disko $DISKO_REV"
    DISKO=$("${NIX[@]}" build --no-link --print-out-paths \
        "github:nix-community/disko/${DISKO_REV}")/bin/disko
    [[ -x "$DISKO" ]] || die "disko CLI did not build"
}

done_select() { [[ -f "$ANSWERS" ]]; }
phase_select() {
    if [[ -z "${hostname:-}" ]]; then
        log "Select the host to install"
        local hosts
        # The same enumeration home/bash.nix uses. Family laptops have no hosts/<name>.nix,
        # so listing that directory cannot name them.
        hosts=$("${NIX[@]}" eval --raw '.#nixosConfigurations' \
            --apply 'c: builtins.concatStringsSep "\n" (builtins.attrNames c)')
        if command -v fzf >/dev/null; then
            hostname=$(printf '%s\n' "$hosts" | fzf --prompt="host: ") || true
        else
            select h in $hosts; do hostname="$h"; break; done
        fi
        [[ -n "${hostname:-}" ]] || die "no host selected"
    fi
    log "Host: $hostname"

    local sysdev homedev datadev encrypt rootmode swapsize datafs
    sysdev=$(pick_disk "Disk for /boot and /")
    homedev=$(pick_disk "Separate disk for /home" true)
    [[ "$homedev" != "$sysdev" ]] || die "the /home disk and the system disk are the same device"

    encrypt=false; ask_yn "Encrypt with LUKS2?" y && encrypt=true

    rootmode=subvol
    ask_yn "Ephemeral tmpfs root (impermanence)?" n && rootmode=tmpfs

    read -rp "Btrfs swapfile size (e.g. 32G, Enter for none): " swapsize

    datadev=""; datafs=btrfs
    if ask_yn "Mount an existing /data filesystem (never formatted)?" n; then
        lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
        echo "For a multi-device btrfs, any one member works: the shared UUID assembles the array."
        local dname duuid
        read -rp "Partition to mount at /data (e.g. sdb1): " dname
        duuid=$(sudo blkid -s UUID -o value "/dev/$dname") || die "no filesystem on /dev/$dname"
        datafs=$(sudo blkid -s TYPE -o value "/dev/$dname")
        datadev="/dev/disk/by-uuid/$duuid"
        if [[ "$datafs" == btrfs ]]; then
            sudo btrfs device scan >/dev/null 2>&1 || true
            local ndev
            ndev=$(sudo btrfs filesystem show "$duuid" 2>/dev/null | grep -c devid || true)
            (( ${ndev:-1} > 1 )) && warn "multi-device btrfs (${ndev} devices): all must be present at boot"
        fi
    fi

    cat > "$ANSWERS" <<EOF
hostname=$hostname
sysdev=$(by_id_for "$sysdev")
homedev=${homedev:+$(by_id_for "$homedev")}
encrypt=$encrypt
rootmode=$rootmode
swapsize=$swapsize
datadev=$datadev
datafs=$datafs
EOF
    render_disk_config
}

render_disk_config() {
    # shellcheck disable=SC1090
    source "$ANSWERS"
    local out="$REPO/disk-config/${hostname}.nix"
    mkdir -p "$REPO/disk-config"
    {
        echo "# ${hostname}'s disks. The by-id paths are read only by \`disko --mode format\`;"
        echo "# the booted system mounts by partlabel, so they need not be right to boot."
        echo "{"
        echo "  fleet.disk = {"
        echo "    enable = true;"
        echo "    system.device = \"${sysdev}\";"
        echo "    system.encrypt = ${encrypt};"
        [[ -n "$homedev" ]] && {
            echo "    home.device = \"${homedev}\";"
            echo "    home.encrypt = ${encrypt};"
        }
        echo "    rootMode = \"${rootmode}\";"
        [[ -n "$swapsize" ]] && echo "    swapSize = \"${swapsize}\";"
        [[ -n "$datadev" ]] && {
            echo "    data.device = \"${datadev}\";"
            echo "    data.fsType = \"${datafs}\";"
        }
        echo "  };"
        echo "}"
    } > "$out"

    # Untracked files are invisible to flake evaluation, and disko reads the flake.
    git -C "$REPO" add "disk-config/${hostname}.nix"
    log "Wrote disk-config/${hostname}.nix"
    cat "$out"
}

done_partition() {
    mountpoint -q "$TARGET" && is_marked partition
}
phase_partition() {
    # shellcheck disable=SC1090
    source "$ANSWERS"

    printf '\n\e[1;31m'
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!!  EVERYTHING ON THE FOLLOWING DISKS WILL BE LOST  !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    printf '\e[0m\n'
    echo "  system: $sysdev"
    [[ -n "$homedev" ]] && echo "  /home:  $homedev"
    [[ -n "$datadev" ]] && echo "  /data:  $datadev  (PRESERVED, not formatted)"
    echo
    local confirmation
    read -rp "Type ERASE to continue: " confirmation
    [[ "$confirmation" == "ERASE" ]] || die "not confirmed"

    if [[ "$encrypt" == true ]]; then
        # One passphrase for every LUKS volume on the host, so systemd's password cache
        # opens the second disk without a second prompt at boot.
        local p1 p2
        while true; do
            read -rsp "LUKS passphrase: " p1; echo
            read -rsp "Again: " p2; echo
            [[ "$p1" == "$p2" && -n "$p1" ]] && break
            echo "Passphrases did not match."
        done
        ( umask 077; printf '%s' "$p1" > "$LUKS_KEY" )
        unset p1 p2
    fi

    log "Partitioning with disko"
    sudo "$DISKO" --mode destroy,format,mount --yes-wipe-all-disks \
        --flake "$REPO#${hostname}"

    mark_done partition
}

done_hardware() {
    local f="$REPO/hardware/${hostname}.nix"
    [[ -f "$f" ]] && ! grep -q '_placeholder' "$f"
}
phase_hardware() {
    log "Generating hardware configuration"
    sudo nixos-generate-config --root "$TARGET" --no-filesystems
    local generated="$TARGET/etc/nixos/hardware-configuration.nix"
    local dest="$REPO/hardware/${hostname}.nix"

    # Never clobber a hand-tuned file: sulfur's kernelParams and hydrogen's quirks live
    # here and nixos-generate-config does not know about them.
    if [[ -f "$dest" ]] && ! grep -q '_placeholder' "$dest"; then
        warn "hardware/${hostname}.nix already exists and is not a placeholder; leaving it alone"
        return 0
    fi
    sudo cp "$generated" "$dest"
    sudo chown "$(id -u):$(id -g)" "$dest"
    git -C "$REPO" add "hardware/${hostname}.nix"
    log "Wrote hardware/${hostname}.nix (kernel modules only; disko owns the mounts)"
}

done_config() { [[ -f "$DEST/flake.nix" ]] && diff -q "$REPO/disk-config/${hostname}.nix" \
    "$DEST/disk-config/${hostname}.nix" >/dev/null 2>&1; }
phase_config() {
    log "Copying the configuration to ${DEST#"$TARGET"}"
    sudo mkdir -p "$(dirname "$DEST")"
    sudo rm -rf "$DEST"
    sudo cp -r "$REPO" "$DEST"
}

done_secrets() { [[ -s "${TARGET}${fact_ageKeyFile}" ]]; }
phase_secrets() {
    local enc
    # The family key decrypts secrets/family.yaml and nothing else -- not the Borg
    # repository key, not the Nextcloud admin password. See .sops.yaml.
    if [[ "$fact_sopsFile" == family.yaml ]]; then
        enc="$REPO/secrets/family-age-key.enc"
    else
        enc="$REPO/secrets/age-key.enc"
    fi
    [[ -f "$enc" ]] || die "$enc is missing; restore it from git before installing"

    log "Installing the age key at $fact_ageKeyFile"
    sudo mkdir -p "$(dirname "${TARGET}${fact_ageKeyFile}")"
    if age_decrypt "$enc" | sudo tee "${TARGET}${fact_ageKeyFile}" >/dev/null; then
        sudo chmod 600 "${TARGET}${fact_ageKeyFile}"
    else
        sudo rm -f "${TARGET}${fact_ageKeyFile}"
        die "could not decrypt $enc"
    fi

    if [[ "$fact_persistSsh" == "true" ]]; then
        log "Generating persistent SSH host keys"
        sudo mkdir -p "$TARGET/persist/etc/ssh"
        [[ -f "$TARGET/persist/etc/ssh/ssh_host_ed25519_key" ]] || \
            sudo ssh-keygen -t ed25519 -f "$TARGET/persist/etc/ssh/ssh_host_ed25519_key" -N ""
        [[ -f "$TARGET/persist/etc/ssh/ssh_host_rsa_key" ]] || \
            sudo ssh-keygen -t rsa -b 4096 -f "$TARGET/persist/etc/ssh/ssh_host_rsa_key" -N ""
    fi

    if [[ "$fact_rootPassword" == "persist" ]]; then
        log "Setting root's password (read from /persist/secrets/root-password at boot)"
        sudo mkdir -p "$TARGET/persist/secrets"
        sudo chmod 700 "$TARGET/persist/secrets"
        mkpasswd -m sha-512 | sudo tee "$TARGET/persist/secrets/root-password" >/dev/null
        sudo chmod 600 "$TARGET/persist/secrets/root-password"
    fi
}

# Decrypt $1 to stdout with whatever age implementation the live environment has.
age_decrypt() {
    if command -v age >/dev/null; then age -d "$1"
    elif command -v rage >/dev/null; then rage -d "$1"
    else "${NIX[@]}" run nixpkgs#age -- -d "$1"
    fi
}

done_install() { [[ -e "$TARGET/nix/var/nix/profiles/system" ]]; }
phase_install() {
    log "Running nixos-install"
    sudo nixos-install --root "$TARGET" --flake "${DEST}#${hostname}"
    mark_done install
}

done_finalize() { false; }
phase_finalize() {
    # users/sheath.nix sets no createHome, so NixOS will not chown a home that the
    # installer already created as root.
    sudo nixos-enter --root "$TARGET" -c 'chown -R sheath:sheath /home/sheath' || \
        warn "could not chown /home/sheath; fix it after first boot"

    log "Installation finished"
    cat <<EOF

Commit the generated files -- every host rebuilds from github:seandheath/nixos
nightly, and a machine whose layout is not in the repo will switch away from it:

    git -C "$REPO" commit -m 'feat(${hostname}): disk layout and hardware config'
    git -C "$REPO" push

EOF
    if [[ "$fact_mutableUsers" == "false" ]]; then
        echo "Passwords on ${hostname} are declarative; there is no passwd to run."
    else
        echo "Dropping into the new system: run 'passwd sheath', then exit."
        sudo nixos-enter --root "$TARGET"
    fi
    sudo rm -f "$STATE"
}

# --- driver ----------------------------------------------------------------------------

resume=false
from=""
hostname=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume) resume=true ;;
        --from) from="${2:?}"; shift ;;
        --host) hostname="${2:?}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
    shift
done

phase_preflight

if [[ "$resume" == true ]]; then
    # After an ISO reboot nothing is mounted, so the state file cannot be read until the
    # target is back. Mounting needs only the committed layout -- disko opens LUKS and
    # mounts by partlabel, with no by-id path involved.
    if ! mountpoint -q "$TARGET"; then
        [[ -n "$hostname" ]] || die "pass --host to resume with nothing mounted"
        log "Re-mounting ${hostname}'s filesystems"
        sudo "$DISKO" --mode mount --flake "$REPO#${hostname}"
    fi
    [[ -f "$ANSWERS" ]] || warn "$ANSWERS is gone; phases needing it will re-ask"
fi

# The answers file carries the host across a resume; --host overrides it.
if [[ -z "$hostname" && -f "$ANSWERS" ]]; then
    # shellcheck disable=SC1090
    source "$ANSWERS"
fi
[[ -n "${hostname:-}" ]] || phase_select
load_facts

if [[ -n "$from" ]]; then
    printf '%s\n' "${PHASES[@]}" | grep -qx "$from" || die "unknown phase: $from"
fi

started=false
for phase in "${PHASES[@]}"; do
    [[ "$phase" == preflight ]] && continue
    if [[ -n "$from" ]]; then
        [[ "$phase" == "$from" ]] && started=true
        [[ "$started" == true ]] || continue
    elif "done_$phase"; then
        log "skipping $phase (already done)"
        continue
    fi
    "phase_$phase"
done
