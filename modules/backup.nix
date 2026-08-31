{ config, pkgs, lib, ... }:
# Borg backups of hydrogen's service data, in three repos answering different failures:
#   /data/borg          fast restores, but on the same RAID0 array as the immich media
#   BorgBase            offsite; the only copy that survives losing the machine
#   /var/backup/borg    on the root SSD, so it survives /data failing
#
# The third is an independent job, not an rsync mirror: a mirror copies any damage in the
# source and carries the same Repository ID, which collides in /root/.cache/borg.
#
# CLI, all as root: `borg-cmd backup` runs every repository under one consistent
# Minecraft checkpoint.  `borg-cmd backup --data|--remote|--rootfs` selects repositories;
# `borg-cmd data|remote|rootfs <borg arguments>` is for raw Borg maintenance.
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
    "/var/lib/minecraft"       # the world (see minecraftFlush below) + server.properties

    # The on-demand worlds, one directory per server. The parent covers servers created
    # after this line was written; without it a world made from the launcher is silently
    # unprotected. Not flushed like the shared world below -- see the note there.
    "/var/lib/minecraft-servers"
    # Active Valheim saves plus Odin's hourly and clean-shutdown snapshots.
    "/var/lib/valheim"
    # Bare git repos. No flush hook like Minecraft's: the object store is append-only and
    # a ref update is an atomic rename, so a live push cannot tear an archive.
    "/var/lib/git"
    # Mutable web-managed searches, browser login state, cache, and logs.
    "/var/lib/ai-marketplace-monitor"

    # The postgresql subdirectory, NOT /var/backup -- widening it to the parent sweeps the
    # rootfs repo into every job, so each backup would archive a copy of the backups.
    "/var/backup/postgresql"

    # The whole Minecraft payload as a local binary cache. The flake can rebuild it only
    # while Mojang and Modrinth keep serving these exact versions; with this, `nix copy
    # --from` plus the flake is enough. Borg dedups it to nothing on nights the pins hold.
    "/var/lib/minecraft-archive"

    # Small user state that has no service-owned home elsewhere. Kilobytes: players.json
    # (authoritative once created, so anyone added from the couch exists only here) plus
    # each player's options.txt and Controlify bindings. The world is server-side.
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
  # The on-demand worlds have no console FIFO; they are reached by RCON through their own
  # containers, as mcctl, whose rootless podman needs its runtime directory named. Both
  # halves end in `|| true`: a world that cannot be reached is not worth failing a backup
  # over, and freeze is only an optimisation over Minecraft's own autosave.
  mcServers = verb: ''
    ${pkgs.coreutils}/bin/timeout 30 ${pkgs.sudo}/bin/sudo -u mcctl \
      XDG_RUNTIME_DIR=/run/user/${toString config.users.users.mcctl.uid} \
      ${lib.getExe pkgs.minecraft-server-ctl} ${verb} >/dev/null 2>&1 || true
  '';

  minecraftFlush = ''
    ${mcConsole "save-off"}
    ${mcConsole "save-all flush"}
    ${lib.optionalString (config.fleet.minecraftServers.enable or false) (mcServers "freeze")}
    ${pkgs.coreutils}/bin/sleep 5
  '';
  minecraftResume = pkgs.writeShellScript "minecraft-save-on" (
    mcConsole "save-on"
    + lib.optionalString (config.fleet.minecraftServers.enable or false) (mcServers "thaw")
  );

  # Hold one save-off/save-on boundary over an entire group of Borg jobs.  Per-job hooks
  # cannot coordinate concurrent units: whichever finishes first would re-enable autosave
  # while another archive was still reading the world.
  runBorgJobs = ''
    ${pgRefresh}
    ${minecraftFlush}
    trap '${minecraftResume}' EXIT

    rc=0
    for job in "$@"; do
      echo
      echo "=== borg $job: archive + prune ==="
      if ! ${pkgs.systemd}/bin/systemctl start --wait "borgbackup-job-$job.service"; then
        echo "borg backup: $job FAILED -- continuing with the remaining repositories." >&2
        rc=1
      fi
    done
    exit "$rc"
  '';


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

  # One lock covers both the scheduled service and manually selected backups.  A second
  # invocation fails clearly rather than starting another archive with a competing
  # save-off/save-on boundary.
  borgFleetRunnerUnlocked = pkgs.writeShellScript "borg-cmd-run-unlocked" runBorgJobs;
  borgFleetRunner = pkgs.writeShellScript "borg-cmd-run" ''
    exec ${pkgs.util-linux}/bin/flock -n /run/lock/fleet-borg-backup.lock \
      ${borgFleetRunnerUnlocked} "$@"
  '';

  borgFleet = pkgs.writeShellScriptBin "borg-cmd" ''
    set -eu

    usage() {
      ${pkgs.coreutils}/bin/cat >&2 <<'EOF'
Usage:
  borg-cmd backup [--data] [--remote] [--rootfs]
  borg-cmd <data|remote|rootfs> <borg command> [arguments...]

Without repository flags, `backup` archives data, remote, then rootfs under one
Minecraft checkpoint. The repository subcommands are for raw Borg maintenance.
EOF
      exit 2
    }

    [ "$#" -gt 0 ] || usage
    case "$1" in
      backup)
        shift
        targets=()
        add_target() {
          for target in "''${targets[@]}"; do
            [ "$target" = "$1" ] && return
          done
          targets+=("$1")
        }
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --data) add_target data ;;
            --remote) add_target remote ;;
            --rootfs) add_target rootfs ;;
            --help|-h) usage ;;
            *) echo "borg-cmd backup: unknown flag: $1" >&2; usage ;;
          esac
          shift
        done
        [ "''${#targets[@]}" -gt 0 ] || targets=(data remote rootfs)
        exec ${borgFleetRunner} "''${targets[@]}"
        ;;
      data|remote|rootfs)
        repo="$1"
        shift
        [ "$#" -gt 0 ] || usage
        export BORG_PASSCOMMAND=${lib.escapeShellArg passCommand}
        case "$repo" in
          data) export BORG_REPO=${lib.escapeShellArg dataRepo} ;;
          remote)
            export BORG_REPO=${lib.escapeShellArg remoteRepo}
            export BORG_RSH=${lib.escapeShellArg remoteRsh}
            ;;
          rootfs) export BORG_REPO=${lib.escapeShellArg rootRepo} ;;
        esac
        exec ${pkgs.borgbackup}/bin/borg "$@"
        ;;
      --help|-h) usage ;;
      *) echo "borg-cmd: unknown command: $1" >&2; usage ;;
    esac
  '';
in
{
  sops.secrets.borg-passphrase = { };
  sops.secrets.borg-ssh-key = { };

  environment.systemPackages = [ borgFleet ];

  # Dumps are started and awaited by fleet-borg-backup, immediately before its archives.
  services.postgresqlBackup = {
    enable = true;
    databases = [ "nextcloud" "immich" ];
    compression = "zstd";
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
  };

  services.borgbackup.jobs.remote = {
    paths = backupPaths;
    exclude = backupExclude;
    repo = remoteRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    environment.BORG_RSH = remoteRsh;
    compression = "zstd";
    inherit prune;
  };

  # Scheduled by fleet-borg-backup after the data and remote jobs.  Serializing all three
  # keeps one consistent Minecraft checkpoint and avoids competing reads from /data.
  services.borgbackup.jobs.rootfs = {
    paths = backupPaths;
    exclude = backupExclude;
    repo = rootRepo;
    encryption = { mode = "repokey-blake2"; inherit passCommand; };
    compression = "zstd";
    inherit prune;
  };

  systemd.services.fleet-borg-backup = {
    description = "Run all Borg repositories from one consistent Minecraft checkpoint";
    startAt = "03:00";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${borgFleetRunner} data remote rootfs";
    };
    unitConfig.RequiresMountsFor = "/data";
  };

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
