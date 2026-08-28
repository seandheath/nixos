# Proton desktop applications and the GroundedGadgets Drive workflow.
#
# Proton still has no native Linux Drive sync client. sulfur therefore uses rclone's
# bidirectional Proton Drive backend, while hydrogen keeps a pull-only mirror for Borg.
# The rclone credentials stay in ~/.config/rclone/rclone.conf and are created interactively
# by `proton-drive-setup`; they never enter this repository or the Nix store.
{ config, lib, pkgs, ... }:

let
  hostName = config.networking.hostName;
  workstation = hostName == "sulfur";
  backupHost = hostName == "hydrogen";
  enabled = workstation || backupHost;

  user = "sheath";
  home = config.users.users.${user}.home;
  localDirectory = "${home}/GroundedGadgets";
  remoteName = "proton-drive";
  remoteDirectory = "${remoteName}:GroundedGadgets";
  sentinel = ".proton-drive-sync";
  stateDirectory = "${home}/.local/state/proton-drive-bisync";
  initialized = "${stateDirectory}/initialized";
  rclone = lib.getExe pkgs.rclone;

  # Proton Drive's rclone backend has no event feed. Disable its metadata cache so a web,
  # mobile, or second-machine change is visible, and keep concurrency low to avoid
  # tripping Proton's API protection. The sentinel makes --check-access able to distinguish
  # an empty folder from a failed/empty remote listing before it propagates deletions.
  protonFlags = [
    "--protondrive-enable-caching=false"
    "--protondrive-replace-existing-draft=true"
    "--transfers=1"
    "--checkers=1"
  ];
  bisyncFlags = protonFlags ++ [
    "--create-empty-src-dirs"
    "--check-access"
    "--check-filename=${sentinel}"
    "--compare=size,modtime"
    "--resilient"
    "--recover"
    "--max-lock=10m"
    "--max-delete=25"
    "--conflict-resolve=newer"
    "--conflict-loser=pathname"
  ];

  bisync = pkgs.writeShellScript "proton-drive-bisync" ''
    set -eu
    exec ${rclone} bisync \
      ${lib.escapeShellArg localDirectory} \
      ${lib.escapeShellArg remoteDirectory} \
      ${lib.escapeShellArgs bisyncFlags}
  '';

  mirror = pkgs.writeShellScript "proton-drive-mirror" ''
    set -eu

    if ! ${rclone} listremotes | ${pkgs.gnugrep}/bin/grep -Fxq \
      ${lib.escapeShellArg "${remoteName}:"}; then
      echo "Proton Drive mirror skipped: run proton-drive-setup on hydrogen first." >&2
      exit 0
    fi

    exec ${rclone} sync \
      ${lib.escapeShellArg remoteDirectory} \
      ${lib.escapeShellArg localDirectory} \
      --create-empty-src-dirs \
      --max-delete=25 \
      ${lib.escapeShellArgs protonFlags}
  '';

  setup = pkgs.writeShellScriptBin "proton-drive-setup" ''
    set -eu

    local_directory=${lib.escapeShellArg localDirectory}
    remote_directory=${lib.escapeShellArg remoteDirectory}
    sentinel=${lib.escapeShellArg sentinel}

    ${pkgs.coreutils}/bin/mkdir -p "$local_directory"

    if ! ${rclone} listremotes | ${pkgs.gnugrep}/bin/grep -Fxq \
      ${lib.escapeShellArg "${remoteName}:"}; then
      ${pkgs.coreutils}/bin/cat <<'EOF'
Create a new rclone remote with these values:
  name:    proton-drive
  storage: Proton Drive

The configuration is stored privately in ~/.config/rclone/rclone.conf.
EOF
      ${rclone} config
    fi

    if ! ${rclone} listremotes | ${pkgs.gnugrep}/bin/grep -Fxq \
      ${lib.escapeShellArg "${remoteName}:"}; then
      echo "proton-drive-setup: the proton-drive remote was not created" >&2
      exit 1
    fi

    ${rclone} mkdir "$remote_directory" ${lib.escapeShellArgs protonFlags}

    if [ ! -e "$local_directory/$sentinel" ]; then
      ${pkgs.coreutils}/bin/printf '%s\n' \
        'Access sentinel for the GroundedGadgets Proton Drive sync.' \
        > "$local_directory/$sentinel"
    fi
    ${rclone} copyto \
      "$local_directory/$sentinel" \
      "$remote_directory/$sentinel" \
      ${lib.escapeShellArgs protonFlags}

    ${lib.optionalString workstation ''
      # The first bisync must establish its two history listings. Prefer the newer copy
      # when a same-named file already exists on both sides; unique files are merged.
      ${rclone} bisync \
        "$local_directory" \
        "$remote_directory" \
        --resync-mode=newer \
        ${lib.escapeShellArgs bisyncFlags}

      ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg stateDirectory}
      ${pkgs.coreutils}/bin/touch ${lib.escapeShellArg initialized}
      ${pkgs.systemd}/bin/systemctl --user start proton-drive-bisync.timer
      echo "GroundedGadgets initialized; bidirectional sync is now scheduled every 15 minutes."
    ''}

    ${lib.optionalString backupHost ''
      ${mirror}
      echo "GroundedGadgets mirror initialized; hydrogen will refresh it hourly and before Borg."
    ''}
  '';
in
{
  config = lib.mkIf enabled {
    environment.systemPackages =
      [ pkgs.rclone setup ]
      ++ lib.optionals workstation [
        pkgs.protonmail-desktop
        pkgs.proton-pass
      ];

    # Exists before either the interactive setup or Borg sees the path. Restrictive by
    # default because it is both cloud-synchronized and backed up offsite.
    systemd.tmpfiles.rules = [
      "d ${localDirectory} 0700 ${user} ${config.users.users.${user}.group} -"
    ];

    home-manager.users.${user} = lib.mkIf workstation {
      systemd.user.services.proton-drive-bisync = {
        Unit = {
          Description = "Bidirectionally sync GroundedGadgets with Proton Drive";
          Documentation = "https://rclone.org/bisync/";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "oneshot";
          ExecCondition = "${pkgs.coreutils}/bin/test -f ${initialized}";
          ExecStart = bisync;
          UMask = "0077";
        };
      };

      systemd.user.timers.proton-drive-bisync = {
        Unit.Description = "Periodically sync GroundedGadgets with Proton Drive";
        Timer = {
          OnBootSec = "5m";
          OnUnitActiveSec = "15m";
          RandomizedDelaySec = "1m";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };

    # hydrogen is a read-only consumer of the cloud folder. Borg calls this unit before
    # taking an archive, and the timer also keeps the local restore copy reasonably fresh.
    systemd.services.proton-drive-mirror = lib.mkIf backupHost {
      description = "Pull GroundedGadgets from Proton Drive for Borg";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = config.users.users.${user}.group;
        ExecStart = mirror;
        UMask = "0077";
      };
      environment = {
        HOME = home;
        XDG_CONFIG_HOME = "${home}/.config";
        XDG_CACHE_HOME = "${home}/.cache";
        XDG_STATE_HOME = "${home}/.local/state";
      };
    };

    systemd.timers.proton-drive-mirror = lib.mkIf backupHost {
      description = "Periodically refresh the GroundedGadgets Borg mirror";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "5m";
        Persistent = true;
        Unit = "proton-drive-mirror.service";
      };
    };
  };
}
