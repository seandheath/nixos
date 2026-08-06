# Keeps a WireGuard peer's endpoint pointed at the right side of the NAT.
#
# THE PROBLEM. The tunnels are meant to be up all the time, at home as well as away --
# that is what lets hydrogen scope every service to a WireGuard interface and stop
# treating "on the home wifi" as authorisation. But a peer at home has to reach an
# endpoint that resolves to the *public* address, which means bouncing off the gateway
# and back (NAT hairpin). Consumer routers vary on whether they will do that at all,
# and when they do, every at-home byte takes a pointless round trip to the WAN port.
#
# Pointing the endpoint at hydrogen's LAN address instead fixes both -- but wg-quick
# resolves an endpoint exactly once, when the interface comes up, so a laptop that
# leaves the house keeps a 10.0.0.10 that is now someone else's printer.
#
# THE FIX. Re-target the live peer on every network change. `wg set ... endpoint` swaps
# the address without tearing the tunnel down; the next keepalive re-handshakes.
#
# Choosing which address is deliberately not a pure "am I on 10.0.0.0/24?" test: plenty
# of other houses use that subnet, and being wrong there means a child's laptop silently
# has no tunnel. Instead it TRIES the LAN address, waits for a handshake, and falls back
# to the public name if none arrives. That also covers the case where the LAN path is
# blocked for some reason it cannot see.
{ config, lib, pkgs, ... }:
let
  cfg = config.family.wgEndpoint;
  peers = import ./peers.nix;

  script = pkgs.writeShellScript "wg-endpoint" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.wireguard-tools pkgs.iproute2 pkgs.gnugrep pkgs.gawk pkgs.coreutils ]}

    # Seconds since this peer last completed a handshake. A huge number means "never",
    # which is also what we want to conclude when the interface has no such peer.
    handshake_age() {
      hs=$(wg show "$1" latest-handshakes 2>/dev/null | awk -v k="$2" '$1 == k { print $2 }')
      if [ -z "$hs" ] || [ "$hs" = "0" ]; then echo 999999; else echo $(( $(date +%s) - hs )); fi
    }

    configure() { # interface publicKey port
      iface=$1; key=$2; port=$3

      # Nothing to do if wg-quick has not brought the interface up yet; the timer will
      # come back around.
      ip link show "$iface" >/dev/null 2>&1 || return 0

      # Only worth trying the LAN address if we hold one from that subnet at all.
      if ip -4 -o addr show scope global | grep -q 'inet ${peers.lanPrefix}'; then
        wg set "$iface" peer "$key" endpoint "${peers.lanEndpoint}:$port" 2>/dev/null || true

        # Give the handshake a chance. persistentKeepalive is 25s, but a fresh endpoint
        # triggers one immediately, so a few seconds is enough to tell success from
        # "this 10.0.0.0/24 is not ours".
        sleep 5
        if [ "$(handshake_age "$iface" "$key")" -lt 180 ]; then
          echo "$iface: endpoint ${peers.lanEndpoint}:$port (LAN)"
          return 0
        fi
      fi

      wg set "$iface" peer "$key" endpoint "${peers.endpointHost}:$port" 2>/dev/null || true
      echo "$iface: endpoint ${peers.endpointHost}:$port (public)"
    }

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (iface: e: ''configure ${iface} "${e.publicKey}" ${toString e.port}'')
      cfg)}
  '';
in
{
  options.family.wgEndpoint = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        publicKey = lib.mkOption {
          type = lib.types.str;
          description = "Public key of the hub peer whose endpoint should be re-targeted.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Hub listen port for this interface.";
        };
      };
    });
    default = { };
    description = ''
      WireGuard interfaces whose hub endpoint should follow the host between the home
      LAN and the outside world. Keyed by interface name.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services.wg-endpoint = {
      description = "Point WireGuard endpoints at the LAN or public address";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = script;
      };
    };

    # Re-run on every connectivity change. The dispatcher only kicks the unit rather
    # than doing the work: NetworkManager runs these scripts serially and this one
    # sleeps, which would stall every other dispatcher script behind it.
    networking.networkmanager.dispatcherScripts = [{
      type = "basic";
      source = pkgs.writeShellScript "wg-endpoint-dispatch" ''
        ${pkgs.systemd}/bin/systemctl start --no-block wg-endpoint.service
      '';
    }];

    # Safety net for events NetworkManager does not emit -- most often a resume from
    # suspend onto a different network, which is the normal way a laptop moves between
    # home and school.
    systemd.timers.wg-endpoint = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Unit = "wg-endpoint.service";
      };
    };
  };
}
