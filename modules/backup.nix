{ config, pkgs, lib, ... }:
# Backups for hydrogen's service data.
#
# Service data now lives on the root SSD (/var/lib/*). We protect it with Borg, in three
# repos that each answer a different failure:
#   - LOCAL, /data/borg      -- fast restores. Same disk as the immich media it archives.
#   - REMOTE, BorgBase       -- offsite. The only copy that survives losing the machine.
#   - ROOTFS, /var/backup/borg -- survives /data failing. See below.
#
# WHY THE THIRD ONE. /data is btrfs RAID0 across two USB-attached rotational disks, so
# either member dying takes the array -- and the array holds BOTH the live /data/immich
# media (180 G) and the local repo. Before this, a /data failure left exactly one copy,
# offsite, and a 180 G restore over WAN. The rootfs repo is a complete local restore point
# that does not live on the array.
#
# It is a THIRD JOB, not an rsync mirror of /data/borg. An independent repo has its own
# chunk index and can be `borg check`ed on its own terms; a mirror would faithfully copy
# any damage in the source and would carry the same Repository ID, which then collides
# with the original in /root/.cache/borg.
#
# Nextcloud + Immich share the main PostgreSQL instance, so we take consistent
# pg_dumps with services.postgresqlBackup (just before Borg runs) and archive the
# dumps. paperless + calibre-web use SQLite inside their data dirs, which Borg
# captures directly. Redis is cache-only and is not backed up.
#
# CLI: `borg-local`, `borg-remote` and `borg-rootfs` (run as root) wrap the borg binary
# with the matching repo + credentials preset, so e.g. `sudo borg-local list` or
# `sudo borg-remote extract ::ARCHIVE path` just work. The synthetic subcommand
# `sudo borg-<local|remote|rootfs> backup` runs an on-demand backup: it refreshes the
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
    # Consistent pg_dumps (nextcloud + immich). NOTE the path is the postgresql
    # subdirectory, NOT /var/backup -- widening it to the parent would sweep the rootfs
    # repo (rootRepo below, /var/backup/borg) into every job, i.e. each backup would
    # archive a copy of the backups. Keep this specific.
    "/var/backup/postgresql"

    # Everything the Minecraft clients need in order to exist at all: the game jar,
    # 115 libraries, 424 MiB of assets, the JVM, the mod jars and the server, as a
    # local Nix binary cache (services.minecraftClient.archiveDir, hosts/hydrogen.nix).
    # ~1.6 GB, and borg dedups it to nothing on the nights when the pins have not
    # moved -- which is most nights, because store paths only change when they do.
    #
    # WHY BACK UP SOMETHING THE FLAKE CAN REBUILD. It can rebuild it from Mojang,
    # Modrinth and maven.fabricmc.net -- while those keep serving these exact versions.
    # Mojang has removed old releases before and Modrinth projects get deleted by their
    # authors. With this directory, `nix copy --from` plus the flake is enough.
    "/var/lib/minecraft-archive"

    # The couch Minecraft client state (see couchCaveat below). This is the only
    # thing under sheath's home that is backed up -- /home is otherwise not in
    # this list at all.
    "${home}/.local/share/minecraft-couch"
  ];

  # couchCaveat: the world itself is server-side and already covered by
  # /var/lib/minecraft, so losing this costs nobody their character or their
  # builds. What it holds is the state that is NOT reproducible from the flake
  # and is tedious to rebuild by hand:
  #   - players.json, the roster. Seeded once from seedPlayers and authoritative
  #     thereafter, so anyone added from the couch exists only here.
  #   - each player's options.txt and config/ -- their video settings and their
  #     Controlify button bindings, redone per child if lost.
  # It is kilobytes per player. The game itself is not in there: since the move off
  # Prism (2026-08-05) it is a read-only store path every player shares, archived
  # once as /var/lib/minecraft-archive above, and each player's mods/ is a symlink
  # into it -- which borg stores as a symlink rather than following.
  backupExclude = [ ];
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
  # On the root SSD, so it survives /data (see the header). Deliberately NOT under any
  # backupPaths entry -- /var/backup/postgresql is listed, /var/backup is not, and that
  # distinction is what keeps the jobs from archiving this repo into themselves.
  rootRepo = "/var/backup/borg";
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
    (mkBorgCli { name = "rootfs"; repo = rootRepo; })
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

  # The third copy, on the root SSD. Same paths, same retention, same everything as the
  # other two -- the point is that it is the same mechanism, so there is nothing extra to
  # understand at restore time and `borg-rootfs` behaves exactly like `borg-local`.
  #
  # 04:30 RATHER THAN 03:00, for two reasons. The existing pair already fire together and
  # already race over the Minecraft autosave: each wraps its run in save-off/flush … and
  # re-enables autosave from ExecStopPost, so whichever finishes first turns saving back
  # on while the other is still archiving. A third concurrent job would widen that window
  # and add a third reader to the same two USB spindles. Staggering sidesteps both without
  # disturbing the pre-existing pair.
  #
  # Everything else a local repo needs is handled by the nixpkgs module: it creates the
  # repo directory via tmpfiles, runs `borg init` on first use (doInit), adds
  # RequiresMountsFor and ReadWritePaths for the repo path, and already runs the job at
  # idle CPU and I/O priority.
  services.borgbackup.jobs.rootfs = {
    paths = backupPaths;
    exclude = backupExclude;
    repo = rootRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    compression = "zstd";
    inherit prune;
    startAt = "*-*-* 04:30:00";
    preHook = minecraftFlush;
  };

  # Always re-enable the world autosave, even if borg failed. See minecraftFlush.
  systemd.services.borgbackup-job-local.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];
  systemd.services.borgbackup-job-remote.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];
  systemd.services.borgbackup-job-rootfs.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];

  # The local job writes to /data — don't run it before the disk is mounted.
  systemd.services.borgbackup-job-local.unitConfig.RequiresMountsFor = "/data";

  # The rootfs job WRITES to root but READS /data/immich, and the module only derives
  # RequiresMountsFor from the repo path. Without this, a boot with the array absent runs
  # the job against a missing source: borg warns, failOnWarnings turns that into exit 1,
  # and the unit fails for a reason that has nothing to do with its own repo.
  systemd.services.borgbackup-job-rootfs.unitConfig.RequiresMountsFor = "/data";

  # The couch directory exists only once somebody has actually played, which on a
  # fresh install is never. That matters because the borgbackup module sets
  # failOnWarnings = true: borg treats a missing source path as a warning, exits 1,
  # and the whole nightly job FAILS -- not just for Minecraft, for Nextcloud and
  # Immich too. Pre-creating it keeps an empty couch setup from taking the backups
  # down with it, and minecraft-client is happy to find the directory already there.
  #
  # /var/lib/minecraft-archive needs no rule: minecraft-archive.service creates it on
  # the first switch, long before the 03:00 borg run.
  systemd.tmpfiles.rules =
    let
      inherit (config.users.users.sheath) group;
    in
    [
      "d ${home}/.local/share/minecraft-couch 0755 sheath ${group} -"
    ];
}
