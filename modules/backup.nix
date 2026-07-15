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
# CLI: `borg-local` and `borg-remote` (run as root) wrap the borg binary with the
# matching repo + credentials preset, so e.g. `sudo borg-local list` or
# `sudo borg-remote extract ::ARCHIVE path` just work. The synthetic subcommand
# `sudo borg-<local|remote> backup` runs an on-demand backup: it refreshes the
# pg_dumps, then triggers that repo's borg job (archive + prune).
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
    "/var/lib/syncthing"       # synced folders + config.xml (device keys/IDs) + index DB
    "/var/backup/postgresql"   # consistent pg_dumps (nextcloud + immich)
  ];
  prune = { keep = { daily = 7; weekly = 16; monthly = 24; }; };
  passCommand = "cat ${config.sops.secrets.borg-passphrase.path}";

  # Repo targets + transport, shared between the borg jobs and the CLI wrappers
  # so there is a single source of truth.
  localRepo = "/data/borg";   # parent /data is the mount; borg init creates the repo
  # BorgBase repo (an identifier, not a credential — access needs borg-ssh-key + passphrase).
  remoteRepo = "ssh://hl4nxm2t@hl4nxm2t.repo.borgbase.com/./repo";
  remoteRsh =
    "ssh -i ${config.sops.secrets.borg-ssh-key.path} -o StrictHostKeyChecking=accept-new";

  # `borg-<name>`: borg with this repo's env preset, plus a `backup` subcommand
  # that refreshes pg_dumps then runs the systemd job. Must run as root (repo
  # perms, sops-protected key/passphrase, and `systemctl start` of system units).
  mkBorgCli = { name, repo, rsh ? null }:
    pkgs.writeShellScriptBin "borg-${name}" ''
      set -eu
      export BORG_REPO=${lib.escapeShellArg repo}
      export BORG_PASSCOMMAND=${lib.escapeShellArg passCommand}
      ${lib.optionalString (rsh != null) "export BORG_RSH=${lib.escapeShellArg rsh}"}
      if [ "''${1-}" = "backup" ]; then
        echo "Refreshing PostgreSQL dumps (nextcloud, immich)..."
        ${pkgs.systemd}/bin/systemctl start --wait \
          postgresqlBackup-nextcloud.service postgresqlBackup-immich.service
        echo "Running borg ${name} backup (archive + prune)..."
        exec ${pkgs.systemd}/bin/systemctl start --wait borgbackup-job-${name}.service
      fi
      exec ${pkgs.borgbackup}/bin/borg "$@"
    '';
in
{
  sops.secrets.borg-passphrase = { };
  sops.secrets.borg-ssh-key = { };

  environment.systemPackages = [
    (mkBorgCli { name = "local"; repo = localRepo; })
    (mkBorgCli { name = "remote"; repo = remoteRepo; rsh = remoteRsh; })
  ];

  # Consistent Postgres dumps at 02:45, before the 03:00 Borg runs.
  services.postgresqlBackup = {
    enable = true;
    databases = [ "nextcloud" "immich" ];
    compression = "zstd";
    startAt = "*-*-* 02:45:00";
  };

  services.borgbackup.jobs.local = {
    paths = backupPaths;
    repo = localRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 03:00:00";
  };

  services.borgbackup.jobs.remote = {
    paths = backupPaths;
    repo = remoteRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    environment.BORG_RSH = remoteRsh;
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 03:00:00";
  };

  # The local job writes to /data — don't run it before the disk is mounted.
  systemd.services.borgbackup-job-local.unitConfig.RequiresMountsFor = "/data";
}
