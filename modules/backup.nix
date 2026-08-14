{ config, pkgs, lib, ... }:
# Borg backups of hydrogen's service data, in three repos answering different failures:
#   /data/borg          fast restores, but on the same RAID0 array as the immich media
#   BorgBase            offsite; the only copy that survives losing the machine
#   /var/backup/borg    on the root SSD, so it survives /data failing
#
# The third is an independent job, not an rsync mirror: a mirror copies any damage in the
# source and carries the same Repository ID, which collides in /root/.cache/borg.
#
# CLI, all as root: borg-data / borg-rootfs / borg-remote address one repo each and take
# any borg subcommand, plus a synthetic `backup` that refreshes the pg_dumps first.
# borg-local is not a repo -- it runs both on-machine jobs, because "back up this machine"
# became two operations and the second is what silently does not happen.
#
# Secrets in secrets/secrets.yaml: borg-passphrase (KEEP A COPY OFF-HYDROGEN -- without it
# the backups are unrecoverable) and borg-ssh-key.
let
  home = config.users.users.sheath.home;

  backupPaths = [
    "/var/lib/nextcloud"
    "/data/immich"             # media moved off root SSD to the big /data disk
    "/var/lib/paperless"
    "/var/lib/calibre-web"
    "/var/lib/syncthing"       # synced folders + config.xml (device keys/IDs) + index DB
    "/var/lib/minecraft"       # the world (see minecraftFlush below) + server.properties
    # The postgresql subdirectory, NOT /var/backup -- widening it to the parent sweeps the
    # rootfs repo into every job, so each backup would archive a copy of the backups.
    "/var/backup/postgresql"

    # The whole Minecraft payload as a local binary cache. The flake can rebuild it only
    # while Mojang and Modrinth keep serving these exact versions; with this, `nix copy
    # --from` plus the flake is enough. Borg dedups it to nothing on nights the pins hold.
    "/var/lib/minecraft-archive"

    # The only thing under /home that is backed up. Kilobytes: players.json (authoritative
    # once created, so anyone added from the couch exists only here) plus each player's
    # options.txt and Controlify bindings. The world is server-side, under /var/lib/minecraft.
    "${home}/.local/share/minecraft-couch"
  ];

  backupExclude = [ ];
  prune = { keep = { daily = 7; weekly = 16; monthly = 24; }; };
  # Absolute path to cat: borg execs this string itself, so a bare `cat` resolves against
  # the caller's PATH. Minimal environments (systemd-run, a rescue shell) are exactly where
  # a restore happens.
  passCommand = "${pkgs.coreutils}/bin/cat ${config.sops.secrets.borg-passphrase.path}";

  # Minecraft writes region files continuously, so a live archive can capture a half-written
  # chunk. Suspend autosave and checkpoint first via the server's console FIFO; `save-on` is
  # an ExecStopPost rather than a postHook because postHook is skipped on non-zero exit and
  # would leave autosave off until the next restart.
  #
  # The inner script is escaped ONCE, as a unit: escaping only the command and hand-quoting
  # around it makes sh treat the redirection as $0 and the flush silently does nothing.
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


  # Named for the disk, not for "local" -- both this and rootRepo are on the machine.
  dataRepo = "/data/borg";
  # An identifier, not a credential: access needs borg-ssh-key + the passphrase.
  remoteRepo = "ssh://hl4nxm2t@hl4nxm2t.repo.borgbase.com/./repo";
  # Deliberately NOT under any backupPaths entry -- that is what keeps the jobs from
  # archiving this repo into themselves.
  rootRepo = "/var/backup/borg";
  remoteRsh =
    "ssh -i ${config.sops.secrets.borg-ssh-key.path} -o StrictHostKeyChecking=accept-new";

  # Nextcloud and Immich share one PostgreSQL instance, so an archive is consistent only if
  # it carries a dump taken just before it, not last night's.
  pgRefresh = ''
    echo "Refreshing PostgreSQL dumps (nextcloud, immich)..."
    ${pkgs.systemd}/bin/systemctl start --wait \
      postgresqlBackup-nextcloud.service postgresqlBackup-immich.service
  '';

  # borg with this repo's env preset, plus a `backup` subcommand. Root only.
  mkBorgCli = { name, repo, rsh ? null }:
    pkgs.writeShellScriptBin "borg-${name}" ''
      set -eu
      export BORG_REPO=${lib.escapeShellArg repo}
      export BORG_PASSCOMMAND=${lib.escapeShellArg passCommand}
      ${lib.optionalString (rsh != null) "export BORG_RSH=${lib.escapeShellArg rsh}"}
      if [ "''${1-}" = "backup" ]; then
        ${pgRefresh}
        echo "Running borg ${name} backup (archive + prune)..."
        exec ${pkgs.systemd}/bin/systemctl start --wait borgbackup-job-${name}.service
      fi
      exec ${pkgs.borgbackup}/bin/borg "$@"
    '';

  # Both on-machine repos, /data then root. Sequential: they read the same ~197 GiB off the
  # same USB spindles and each wraps its run in save-off/save-on, so run together whichever
  # finishes first re-enables autosave while the other is still archiving. Runs the second
  # even if the first fails -- a failing /data is the scenario the root repo exists for.
  borgLocalCli = pkgs.writeShellScriptBin "borg-local" ''
    set -u

    if [ "$#" -gt 0 ] && [ "$1" != "backup" ]; then
      echo "borg-local runs both on-machine backups; it is not a repo." >&2
      echo "It was the /data repo's wrapper until 2026-08-05. For borg subcommands" >&2
      echo "use the per-repo wrappers instead:" >&2
      echo "  borg-data   $*   (/data/borg)" >&2
      echo "  borg-rootfs $*   (/var/backup/borg)" >&2
      echo "  borg-remote $*   (BorgBase, offsite)" >&2
      exit 2
    fi

    ${pgRefresh}

    rc=0
    for job in data rootfs; do
      echo
      echo "=== borg $job: archive + prune ==="
      if ! ${pkgs.systemd}/bin/systemctl start --wait "borgbackup-job-$job.service"; then
        echo "borg-local: the $job job FAILED -- continuing with the rest." >&2
        rc=1
      fi
    done

    if [ "$rc" -ne 0 ]; then
      echo "borg-local: at least one job failed; check journalctl -u borgbackup-job-*" >&2
    fi
    exit "$rc"
  '';
in
{
  sops.secrets.borg-passphrase = { };
  sops.secrets.borg-ssh-key = { };

  environment.systemPackages = [
    (mkBorgCli { name = "data"; repo = dataRepo; })
    (mkBorgCli { name = "rootfs"; repo = rootRepo; })
    (mkBorgCli { name = "remote"; repo = remoteRepo; rsh = remoteRsh; })
    borgLocalCli
  ];

  # Consistent Postgres dumps at 02:45, before the 03:00 Borg runs.
  services.postgresqlBackup = {
    enable = true;
    databases = [ "nextcloud" "immich" ];
    compression = "zstd";
    startAt = "*-*-* 02:45:00";
  };

  # prune.prefix is "hydrogen", not the default "hydrogen-data": this job was renamed from
  # `local` on 2026-08-05, and the narrower glob would stop matching every archive taken
  # before that -- immortal, holding ~191 GiB that could never be freed. Safe only because
  # nothing else writes to this repo.
  services.borgbackup.jobs.data = {
    paths = backupPaths;
    exclude = backupExclude;
    repo = dataRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    compression = "zstd";
    prune = prune // { prefix = "hydrogen"; };
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

  # 04:30, not 03:00: the other two already fire together and race over the Minecraft
  # autosave, and a third concurrent job would widen that window and add a third reader to
  # the same two USB spindles.
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
  systemd.services.borgbackup-job-data.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];
  systemd.services.borgbackup-job-remote.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];
  systemd.services.borgbackup-job-rootfs.serviceConfig.ExecStopPost = [ "${minecraftResume}" ];

  # The data job writes to /data — don't run it before the disk is mounted.
  systemd.services.borgbackup-job-data.unitConfig.RequiresMountsFor = "/data";

  # This job WRITES to root but READS /data/immich, and the module derives
  # RequiresMountsFor only from the repo path.
  systemd.services.borgbackup-job-rootfs.unitConfig.RequiresMountsFor = "/data";

  # The couch directory exists only once somebody has played. failOnWarnings = true and borg
  # treats a missing source as a warning, so on a fresh install this would fail the entire
  # nightly job -- Nextcloud and Immich included.
  systemd.tmpfiles.rules =
    let
      inherit (config.users.users.sheath) group;
    in
    [
      "d ${home}/.local/share/minecraft-couch 0755 sheath ${group} -"
    ];
}
