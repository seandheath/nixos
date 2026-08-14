# Put a bridge's slave interfaces back if something detaches them.
#
# Bounds, but does not diagnose, the 2026-08-13 outage: br0 lost enp0s31f6 30 ms after
# systemd logged "Reloaded Bridge Interface br0", and nothing put it back for six hours.
# The actor is still unidentified -- two live reproductions cleared NetworkManager. See
# CHANGELOG 2026-08-13 before re-running those experiments.
#
# Deliberately not silent: every repair logs at warning level, so the bug keeps a
# timestamped trail. Those lines appearing IS the reproduction we could not get on demand.
#
# Derived from networking.bridges, so a later bridge is covered and a host with none gets
# nothing. Suspend during deliberate bridge maintenance with
#   systemctl stop bridge-slave-restore.timer
{ config, lib, pkgs, ... }:
let
  bridges = config.networking.bridges;

  # Compares the CURRENT master rather than testing that some master exists: enslaved to
  # the wrong bridge is as broken as enslaved to nothing, and `ip link set` fixes both.
  checks = lib.concatLists (lib.mapAttrsToList (br: brCfg:
    map (iface: ''
      # NOT `readlink -f`: it canonicalises a missing final component and exits 0, so a
      # detached interface reported master=master. The log line is the point of this unit,
      # so it has to say what was actually there.
      if [ -L /sys/class/net/${iface}/master ]; then
        current=$(${pkgs.coreutils}/bin/basename \
          "$(${pkgs.coreutils}/bin/readlink /sys/class/net/${iface}/master)")
      else
        current=""
      fi
      if [ "$current" != "${br}" ]; then
        echo "WARNING: ${iface} is not a slave of ${br} (master=''${current:-none}) -- re-attaching" >&2
        # || true: a failed repair must not leave a failed unit needing its own attention.
        # The next tick retries in 30 s and the warning is already in the journal.
        ${pkgs.iproute2}/bin/ip link set dev ${iface} master ${br} up || true
      fi
    '') brCfg.interfaces) bridges);
in
{
  config = lib.mkIf (bridges != { }) {
    systemd.services.bridge-slave-restore = {
      description = "Re-attach detached bridge slave interfaces";
      serviceConfig.Type = "oneshot";
      script = lib.concatStringsSep "\n" checks;
    };

    systemd.timers.bridge-slave-restore = {
      description = "Periodically check bridge slaves are still attached";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "30s";
        # Load-bearing: the default is 1 minute, and a 30 s period with 60 s of slop is
        # not a 30 s period.
        AccuracySec = "5s";
        Unit = "bridge-slave-restore.service";
      };
    };
  };
}
