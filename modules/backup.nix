{ config, pkgs, lib, ... }:
# Backups for hydrogen's service data.
#
# Service data now lives on the root SSD (/var/lib/*). We protect it with Borg:
#   - a LOCAL repo on /data (the big btrfs disk) for fast restores, and
#   - a REMOTE repo on BorgBase (offsite, the real safety net since /data is RAID0).
#
# Nextcloud + Immich share the main PostgreSQL instance, so we take consistent
# pg_dumps with services.postgresqlBackup (just before Borg runs) and archive the
# dumps. paperless + calibre-web use SQLite inside their data dirs, which Borg
# captures directly. Redis is cache-only and is not backed up.
#
# SECRETS (add to secrets/secrets.yaml via sops):
#   borg-passphrase  - repo encryption passphrase. KEEP A COPY OFF-HYDROGEN; without
#                      it the backups are unrecoverable.
#   borg-ssh-key     - private SSH key whose public half is registered in BorgBase.
let
  backupPaths = [
    "/var/lib/nextcloud"
    "/var/lib/immich"
    "/var/lib/paperless"
    "/var/lib/calibre-web"
    "/var/backup/postgresql"   # consistent pg_dumps (nextcloud + immich)
  ];
  prune = { keep = { daily = 7; weekly = 16; monthly = 24; }; };
  passCommand = "cat ${config.sops.secrets.borg-passphrase.path}";
in
{
  sops.secrets.borg-passphrase = { };
  sops.secrets.borg-ssh-key = { };

  # Consistent Postgres dumps at 02:45, before the 03:00 Borg runs.
  services.postgresqlBackup = {
    enable = true;
    databases = [ "nextcloud" "immich" ];
    compression = "zstd";
    startAt = "*-*-* 02:45:00";
  };

  services.borgbackup.jobs.local = {
    paths = backupPaths;
    repo = "/data/borg";   # parent /data is the mount; borg init creates the repo
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 03:00:00";
  };

  services.borgbackup.jobs.remote = {
    paths = backupPaths;
    # TODO: replace with your BorgBase repo URL (BorgBase UI -> repo -> "Borg" URL).
    repo = "ssh://XXXX@XXXX.repo.borgbase.com/./repo";
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    environment.BORG_RSH =
      "ssh -i ${config.sops.secrets.borg-ssh-key.path} -o StrictHostKeyChecking=accept-new";
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 03:00:00";
  };

  # The local job writes to /data — don't run it before the disk is mounted.
  systemd.services.borgbackup-job-local.unitConfig.RequiresMountsFor = "/data";
}
