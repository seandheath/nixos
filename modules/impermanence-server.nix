# hydrogen's /persist layout. Btrfs subvolumes, no LUKS, and no root-wipe rollback: root
# persists like a normal install, so there is no exhaustive persist list to get wrong. The
# installer's @root-blank snapshot goes unused.
#
# To make root truly ephemeral later: add a boot.initrd.systemd unit restoring @root from
# @root-blank, import the impermanence module, and write a complete
# environment.persistence."/persist" list -- postgresql, acme, syncthing, calibre-web,
# redis, immich, /etc/ssh, /var/lib/nixos, /etc/machine-id.
{ config, lib, pkgs, ... }:
{
  boot.initrd.systemd.enable = true;

  # On /persist rather than under a home, so a fresh install does not leave ~/.config
  # root-owned. The installer decrypts secrets/age-key.enc to here.
  sops.age.keyFile = lib.mkForce "/persist/secrets/age-keys.txt";

  # sops-install-secrets runs from the initrd activation script, BEFORE ordinary
  # filesystems are mounted -- without this the age key is invisible, /run/secrets is never
  # created, and every sops consumer dies with 243/CREDENTIALS. Self-concealing: the next
  # rebuild repairs it, so the system only looks broken between a reboot and that rebuild.
  fileSystems."/persist".neededForBoot = true;

  systemd.tmpfiles.rules = [
    "d /persist 0755 root root -"
    "d /persist/secrets 0700 root root -"
  ];

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/persist" ];
  };
}
