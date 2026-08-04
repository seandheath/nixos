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
  home = config.users.users.sheath.home;

  backupPaths = [
    "/var/lib/nextcloud"
    "/data/immich"             # media moved off root SSD to the big /data disk
    "/var/lib/paperless"
    "/var/lib/calibre-web"
    "/var/lib/syncthing"       # synced folders + config.xml (device keys/IDs) + index DB
    "/var/lib/minecraft"       # the world (see minecraftFlush below) + server.properties
    "/var/lib/veloren"         # characters + terrain diffs (see velorenCaveat below)
    "/var/backup/postgresql"   # consistent pg_dumps (nextcloud + immich)

    # The couch Minecraft client state (see couchCaveat below). This is the only
    # thing under sheath's home that is backed up -- /home is otherwise not in
    # this list at all.
    "${home}/.local/share/minecraft-couch"
    "${home}/.local/share/PrismLauncher"
  ];

  # couchCaveat: the world itself is server-side and already covered by
  # /var/lib/minecraft, so losing these costs nobody their character or their
  # builds. What they hold is the state that is NOT reproducible from the flake
  # and is tedious to rebuild by hand:
  #   - players.json, the roster. Seeded once from seedPlayers and authoritative
  #     thereafter, so anyone added from the couch exists only here.
  #   - each player's options.txt and config/ -- their video settings and their
  #     Controlify button bindings, redone per child if lost.
  #   - the canonical Prism instance and accounts.json (the Microsoft account
  #     that is what unlocks offline launching at all).
  #
  # Excluded below: Prism's re-downloadable trees. assets alone is ~1 GB of game
  # resources fetched from Mojang, and libraries/meta/java are the same story --
  # Prism refetches all of it on first launch. The per-player directories point
  # at these via symlinks, which borg stores as symlinks rather than following,
  # so they cost nothing there either.
  backupExclude = [
    "${home}/.local/share/PrismLauncher/assets"
    "${home}/.local/share/PrismLauncher/libraries"
    "${home}/.local/share/PrismLauncher/meta"
    "${home}/.local/share/PrismLauncher/java"
    "${home}/.local/share/PrismLauncher/cache"
    "${home}/.local/share/PrismLauncher/logs"
  ];
  prune = { keep = { daily = 7; weekly = 16; monthly = 24; }; };
  passCommand = "cat ${config.sops.secrets.borg-passphrase.path}";

  # Minecraft writes region files continuously, so archiving the live world can
  # capture a half-written chunk. The server's console is exposed as a FIFO by
  # services.minecraft-server (ListenFIFO /run/minecraft-server.stdin, held open
  # by the service and removed when it stops). Suspend autosave and checkpoint
  # before the archive; resume after.
  #
  # `save-on` is an ExecStopPost, NOT a postHook: postHook is skipped when borg
  # exits non-zero, which would leave autosave off until the next server restart.
  # ExecStopPost runs on success and failure alike.
  #
  # `timeout` guards against a write blocking forever if the FIFO ever outlives
  # its reader; `|| true` keeps a stopped/absent server from failing the backup.
  #
  # The whole inner script is escaped ONCE, as a unit. Escaping just the command
  # and hand-quoting around it produces `sh -c 'echo 'save-all flush' > fifo'`,
  # which the outer shell splits into two arguments -- sh then treats the second
  # as $0, the redirection never happens, and the flush silently does nothing.
  mcConsole = cmd: ''
    ${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c \
      ${lib.escapeShellArg "echo ${cmd} > /run/minecraft-server.stdin"} || true
  '';
  minecraftFlush = ''
    ${mcConsole "save-off"}
    ${mcConsole "save-all flush"}
    ${pkgs.coreutils}/bin/sleep 5
  '';
  minecraftResume = pkgs.writeShellScript "minecraft-save-on" (mcConsole "save-on");

  # velorenCaveat: unlike Minecraft, veloren-server-cli exposes no console FIFO, so there is
  # no way to checkpoint it before the archive. Borg can therefore capture
  # /var/lib/veloren/server/saves/db.sqlite mid-write. Deliberately left alone rather than
  # wrapped in a stop/start dance: the world itself is not in the backup at all (it is
  # regenerated from world_seed in modules/veloren-server.nix), so the only exposure is a
  # torn character DB, recoverable from the previous night's archive. Revisit if Veloren
  # ever grows a remote console.

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
    exclude = backupExclude;
    repo = localRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 03:00:00";
    preHook = minecraftFlush;
  };

  services.borgbackup.jobs.remote = {
    paths = backupPaths;
    exclude = backupExclude;
    repo = remoteRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    environment.BORG_RSH = remoteRsh;
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 03:00:00";
    preHook = minecraftFlush;
  };

  # Always re-enable the world autosave, even if borg failed. See minecraftFlush.
  systemd.services.borgbackup-job-local.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];
  systemd.services.borgbackup-job-remote.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];

  # The local job writes to /data — don't run it before the disk is mounted.
  systemd.services.borgbackup-job-local.unitConfig.RequiresMountsFor = "/data";

  # These two exist only after Prism has been opened and minecraft-couch-sync has
  # run, which on a fresh install is never. That matters because the borgbackup
  # module sets failOnWarnings = true: borg treats a missing source path as a
  # warning, exits 1, and the whole nightly job FAILS -- not just for Minecraft,
  # for Nextcloud and Immich too. Pre-creating them keeps an empty couch setup
  # from taking the backups down with it. Prism and minecraft-couch-sync are both
  # happy to find the directory already there.
  systemd.tmpfiles.rules =
    let
      inherit (config.users.users.sheath) group;
    in
    [
      "d ${home}/.local/share/minecraft-couch 0755 sheath ${group} -"
      "d ${home}/.local/share/PrismLauncher 0755 sheath ${group} -"
    ];
}
