{ config, lib, pkgs, ... }:
# Server-side "impermanence" layout for hydrogen.
#
# This is the LAYOUT-ONLY variant (matching the repo's actual behaviour on sulphur):
# Btrfs subvolumes @root/@nix/@home/@persist/@log/@swap + a separate /data disk, with
# NO LUKS and NO active root-wipe rollback service. Root persists like a normal install,
# so /etc/shadow and /var/lib (service databases) survive reboots -- which means there is
# no exhaustive persist list to get wrong and no data-loss risk on reboot. The trade-off
# is that root is not actually ephemeral; the installer's @root-blank snapshot is unused
# (same as sulphur today).
{
  # Initrd systemd: matches the repo's other Btrfs hosts. Harmless without LUKS/rollback.
  boot.initrd.systemd.enable = true;

  # /persist skeleton (used today only as the btrfs autoScrub target + future secrets dir).
  systemd.tmpfiles.rules = [
    "d /persist 0755 root root -"
    "d /persist/secrets 0700 root root -"
  ];

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/persist" ];
  };

  # --- Enabling TRUE root-wipe later (currently disabled) ---
  # 1. Add a boot.initrd.systemd.services unit that deletes @root and restores it from
  #    @root-blank before / is mounted.
  # 2. Add impermanence.nixosModules.impermanence to hydrogen's module list in flake.nix
  #    and complete an exhaustive environment.persistence."/persist" list so state survives:
  #      { directory = "/var/lib/postgresql"; user = "postgres"; group = "postgres"; mode = "0700"; }
  #      "/var/lib/acme" "/var/lib/syncthing" "/var/lib/calibre-web" "/var/lib/redis-*"
  #      "/var/lib/immich" "/var/lib/private/immich" "/etc/ssh" "/var/lib/nixos"
  #    plus files = [ "/etc/machine-id" ], programs.fuse.userAllowOther = true,
  #    users.mutableUsers = false, and users.users.{sheath,root}.hashedPasswordFile.
}
