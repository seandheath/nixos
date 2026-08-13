# Put a bridge's slave interfaces back if something detaches them.
#
# THE OUTAGE THIS EXISTS TO BOUND. On 2026-08-13 hydrogen's nightly rebuild completed
# successfully and took the machine off the network for six hours. The host never
# crashed -- journald ran the whole time -- but br0 lost enp0s31f6 and nothing put it
# back, so the LAN address and both WireGuard hubs were unreachable until someone
# walked over and power-cycled it. From `journalctl -b -2`, microsecond precision:
#
#   04:29:00.631  systemd[1]: Reloading Bridge Interface br0...
#   04:29:00.654  kernel: br0: port 1(enp0s31f6) entered forwarding state   <- reload OK
#   04:29:00.655  systemd[1]: Reloaded Bridge Interface br0.
#   04:29:00.685  kernel: br0: port 1(enp0s31f6) entered disabled state     <- 30ms later
#
# br0-netdev.service carries X-ReloadIfChanged=true, so any switch that moves its store
# paths reloads it, which is most nixpkgs bumps. The reload itself is correct: it
# detaches every slave, re-attaches, and ends in `forwarding`. The kill is the SECOND
# detach, 30 ms after systemd already logged "Reloaded".
#
# WHAT WE DO NOT KNOW, stated plainly so nobody re-runs these experiments. The actor is
# unidentified. NetworkManager was the obvious suspect -- it holds autoconnecting
# profiles for both br0 and enp0s31f6, and modules/wg-unmanaged.nix documents NM doing
# exactly this to WireGuard devices -- but two live reproductions on 2026-08-13 cleared
# it:
#   - `systemctl restart NetworkManager` alone: bridge never flinched, kernel silent.
#   - `systemctl reload br0-netdev.service` alone, under NM debug logging: reproduced
#     the detach/re-attach pair, ended in `forwarding`, and NM only observed it
#     ("restarting dynamic IP configuration (interface got carrier)").
# The switch's full action list that night was `reloading: br0-netdev, dbus-broker` /
# `restarting: home-manager-sheath, polkit` / `stopping: accounts-daemon` -- NM and
# systemd-udevd were neither restarted nor reloaded. So the trigger is some interaction
# only a real switch produces, and it is still open.
#
# WHY A WATCHDOG ANYWAY. The failure does not need a diagnosis to be bounded: whatever
# detaches the slave, re-attaching it is correct and idempotent. This converts a
# six-hour outage needing physical access into a <=30 s blip. It is deliberately NOT
# silent -- every repair logs at warning level, so the bug keeps a visible trail with
# timestamps, which is precisely the evidence the investigation above lacked. If those
# lines start appearing, that is the reproduction we could not get on demand.
#
# The list is derived from networking.bridges rather than hardcoded, so a bridge added
# later is covered without anyone remembering this file exists -- same reasoning as
# modules/wg-unmanaged.nix. Imported for every host via commonModules in flake.nix;
# on a host that declares no bridges it defines nothing at all.
#
# To suspend it during deliberate maintenance on a bridge:
#   systemctl stop bridge-slave-restore.timer
{ config, lib, pkgs, ... }:
let
  bridges = config.networking.bridges;

  # One check per (bridge, slave) pair. Compares the CURRENT master rather than merely
  # testing that some master exists: an interface enslaved to the wrong bridge is just
  # as broken as one enslaved to nothing, and `ip link set ... master` fixes both.
  checks = lib.concatLists (lib.mapAttrsToList (br: brCfg:
    map (iface: ''
      current=$(${pkgs.coreutils}/bin/basename \
        "$(${pkgs.coreutils}/bin/readlink -f /sys/class/net/${iface}/master 2>/dev/null || true)" \
        2>/dev/null || true)
      if [ "$current" != "${br}" ]; then
        echo "WARNING: ${iface} is not a slave of ${br} (master=''${current:-none}) -- re-attaching" >&2
        # || true: a failed repair must not leave a failed unit behind that then needs
        # its own attention. The next tick retries in 30 s, and the warning above is
        # already in the journal either way.
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
        # WITHOUT THIS THE TIMER IS USELESS. systemd's default AccuracySec is 1 minute,
        # which it spends by firing anywhere inside that window -- a 30 s period with
        # 60 s of slop is not a 30 s period. The whole value here is a short worst-case
        # outage, so the accuracy has to be tighter than the interval.
        AccuracySec = "5s";
        Unit = "bridge-slave-restore.service";
      };
    };
  };
}
