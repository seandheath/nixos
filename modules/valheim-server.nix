{ config, lib, pkgs, ... }:

# Mostly-vanilla Valheim for the family VPN. The mutable Steam server and world live
# outside the container; the image and Thunderstore dependency strings are fixed here.
let
  cfg = config.services.familyValheim;
  root = "/var/lib/valheim";
  uid = 1101;
  runtimeDir = "/run/user/${toString uid}";

  # amd64 manifest behind docker.io/mbround18/valheim:3 on 2026-08-20. Never use the
  # mutable tag in the unit: an image update is reviewed alongside game/mod compatibility.
  image = "docker.io/mbround18/valheim@sha256:61998cbb2980d2b563879a06d504e8487922cd54735bde7bbaaa4f7eb7f5e583";

  serverMods = [
    "ValheimModding-Jotunn-2.29.2"
    "Azumatt-AzuCraftyBoxes-1.8.15"
    "Goldenrevolver-Quick_Stack_Store_Sort_Trash_Restock-1.4.13"
    "MSchmoecker-MultiUserChest-0.6.1"
    "Azumatt-AAA_Crafting-2.1.6"
    "Azumatt-AzuAreaRepair-1.1.6"
    # Server-only. Keep only if the forced-save/restart smoke test is clean.
    "Smoothbrain-SmoothSave-1.0.5"
  ];
  mods = lib.concatStringsSep "\n" serverMods;

  start = pkgs.writeShellScript "valheim-start" ''
    set -eu

    export XDG_RUNTIME_DIR=${runtimeDir}
    export PASSWORD="$(${pkgs.coreutils}/bin/cat "$CREDENTIALS_DIRECTORY/password")"
    export MODS=${lib.escapeShellArg mods}

    update=0
    if [ ! -x ${root}/server/valheim_server.x86_64 ] || [ -e ${root}/update-on-next-start ]; then
      update=1
    fi

    exec ${pkgs.podman}/bin/podman run --name valheim --replace --pull=missing \
      --security-opt=no-new-privileges --cap-drop=all \
      --userns=keep-id:uid=111,gid=1000 \
      --publish 10.41.0.2:2456-2458:2456-2458/udp \
      --publish 10.42.0.2:2456-2458:2456-2458/udp \
      --volume ${root}/saves:/home/steam/.config/unity3d/IronGate/Valheim:rw \
      --volume ${root}/server:/home/steam/valheim:rw \
      --volume ${root}/backups:/home/steam/backups:rw \
      --env PASSWORD --env MODS \
      --env NAME=Hydrogen --env WORLD=family --env PORT=2456 \
      --env PUBLIC=0 --env ENABLE_CROSSPLAY=0 --env PRESET=Normal \
      --env TYPE=BepInEx --env AUTO_UPDATE=0 --env UPDATE_ON_STARTUP="$update" \
      --env STAGED_UPDATES=1 --env AUTO_BACKUP=1 \
      --env 'AUTO_BACKUP_SCHEDULE=0 * * * *' \
      --env AUTO_BACKUP_REMOVE_OLD=1 --env AUTO_BACKUP_DAYS_TO_LIVE=7 \
      --env AUTO_BACKUP_ON_UPDATE=1 --env AUTO_BACKUP_ON_SHUTDOWN=1 \
      --env TZ=America/New_York \
      ${image}
  '';

  installed = pkgs.writeShellScript "valheim-installed" ''
    set -eu
    # Type=simple runs ExecStartPost as soon as podman itself starts. Give it a short
    # window to create the container, but do not turn a podman startup failure into the
    # full 20-minute SteamCMD timeout.
    for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
      ${pkgs.podman}/bin/podman container exists valheim && break
      ${pkgs.coreutils}/bin/sleep 1
    done
    ${pkgs.podman}/bin/podman container exists valheim || {
      echo "Valheim container was not created" >&2
      exit 1
    }

    # Preserve the update marker across a failed/partial SteamCMD run. Removing it only
    # after the executable appears makes the next service restart retry the update.
    for _ in $(${pkgs.coreutils}/bin/seq 1 240); do
      [ -x ${root}/server/valheim_server.x86_64 ] && {
        ${pkgs.coreutils}/bin/rm -f ${root}/update-on-next-start
        exit 0
      }
      [ "$(${pkgs.podman}/bin/podman inspect --format '{{.State.Running}}' valheim 2>/dev/null || true)" = true ] || {
        echo "Valheim container exited before install/update completed" >&2
        exit 1
      }
      ${pkgs.coreutils}/bin/sleep 5
    done
    echo "Valheim install/update did not finish within 20 minutes" >&2
    exit 1
  '';

  update = pkgs.writeShellScript "valheim-update" ''
    set -eu
    ${pkgs.systemd}/bin/systemctl stop valheim.service
    ${pkgs.coreutils}/bin/touch ${root}/update-on-next-start
    ${pkgs.systemd}/bin/systemctl start valheim.service
  '';
in
{
  options.services.familyValheim.enable =
    lib.mkEnableOption "the private, mostly-vanilla family Valheim server";

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;

    users.users.valheim = {
      isNormalUser = true;
      inherit uid;
      group = "valheim";
      home = root;
      createHome = true;
      description = "Valheim dedicated server";
      linger = true;
    };
    users.groups.valheim = { };

    sops.secrets.valheim-server-password = {
      owner = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d ${root} 0750 valheim valheim -"
      "d ${root}/saves 0750 valheim valheim -"
      "d ${root}/server 0750 valheim valheim -"
      "d ${root}/backups 0750 valheim valheim -"
    ];

    systemd.services.valheim = {
      description = "Hydrogen family Valheim server";
      # Rootless Podman needs the privileged NixOS newuidmap/newgidmap wrappers for
      # subordinate ID mappings. The unwrapped shadow binaries in the store cannot write
      # uid_map/gid_map even when they are on PATH.
      path = [ "/run/wrappers" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" "user@${toString uid}.service" ];
      after = [ "network-online.target" "user@${toString uid}.service" ];
      serviceConfig = {
        Type = "simple";
        User = "valheim";
        Group = "valheim";
        Environment = "XDG_RUNTIME_DIR=${runtimeDir}";
        LoadCredential = "password:${config.sops.secrets.valheim-server-password.path}";
        ExecStartPre = "-${pkgs.podman}/bin/podman rm -f valheim";
        ExecStart = start;
        ExecStartPost = installed;
        ExecStop = "${pkgs.podman}/bin/podman stop --time 180 valheim";
        ExecStopPost = "-${pkgs.podman}/bin/podman rm -f valheim";
        Restart = "on-failure";
        RestartSec = 15;
        TimeoutStartSec = 1300;
        TimeoutStopSec = 240;
      };
    };

    # Deliberately not wantedBy: `sudo systemctl start valheim-update` is the gate.
    systemd.services.valheim-update = {
      description = "Back up and update the pinned Valheim server installation once";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = update;
        TimeoutStartSec = 1500;
      };
    };
  };
}
