# Keeps a WireGuard peer's endpoint pointed at the right side of the NAT.
#
# The tunnels are up all the time, at home as well as away -- that is what lets hydrogen
# stop treating "on the home wifi" as authorisation. But a peer at home reaching a public
# endpoint needs a NAT hairpin, which consumer routers vary on and which costs a pointless
# round trip to the WAN port. Pointing at the LAN address fixes both, except wg-quick
# resolves an endpoint exactly once, so a laptop that leaves the house keeps a 10.0.0.10
# that is now someone else's printer.
#
# So: re-target the live peer on every network change with `wg set ... endpoint`, which
# swaps the address without tearing the tunnel down. Choosing which address is a PROBE, not
# an "am I on 10.0.0.0/24?" test -- plenty of other houses use that subnet, and being wrong
# means a child's laptop silently has no tunnel.
{ config, lib, pkgs, ... }:
let
  cfg = config.family.wgEndpoint;

  # The wg-quick units this host actually declares. Taken from wg-quick's own attrset
  # rather than from cfg, so ordering covers every tunnel on the box -- a peer that
  # roams is not the only one whose interface has to exist before we poke at it.
  wgQuickUnits =
    map (n: "wg-quick-${n}.service") (lib.attrNames config.networking.wg-quick.interfaces);

  script = pkgs.writeShellScript "wg-endpoint" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.wireguard-tools pkgs.iproute2 pkgs.gnugrep pkgs.gawk pkgs.coreutils ]}

    # Seconds since this peer last completed a handshake. A huge number means "never",
    # which is also what we want to conclude when the interface has no such peer.
    handshake_age() {
      hs=$(wg show "$1" latest-handshakes 2>/dev/null | awk -v k="$2" '$1 == k { print $2 }')
      if [ -z "$hs" ] || [ "$hs" = "0" ]; then echo 999999; else echo $(( $(date +%s) - hs )); fi
    }

    configure() { # interface publicKey port lanHost publicHost
      iface=$1; key=$2; port=$3; lan=$4; pub=$5

      # Nothing to do if wg-quick has not brought the interface up yet; the timer will
      # come back around.
      ip link show "$iface" >/dev/null 2>&1 || return 0

      # Already working: leave it alone. Without this the 5-minute timer would tear a
      # healthy public-endpoint tunnel down to re-test the LAN address every time it
      # fired.
      if [ "$(handshake_age "$iface" "$key")" -lt 180 ]; then
        return 0
      fi

      # LAN address first, UNCONDITIONALLY. A subnet test would be wrong: the kids' laptops
      # are on the Kids VLAN and never hold a 10.0.0.x address, so they would skip to the
      # public endpoint, which arrives at our own WAN from the inside and is not DNAT'd.
      # Probing is the honest test -- a foreign network on the same subnet cannot complete
      # a handshake with hydrogen's key.
      wg set "$iface" peer "$key" endpoint "$lan:$port" 2>/dev/null || true

      # persistentKeepalive is 25s, but a freshly-set endpoint triggers a handshake
      # immediately, so a few seconds distinguishes "at home" from "not".
      sleep 5
      if [ "$(handshake_age "$iface" "$key")" -lt 180 ]; then
        echo "$iface: endpoint $lan:$port (LAN)"
        return 0
      fi

      wg set "$iface" peer "$key" endpoint "$pub:$port" 2>/dev/null || true
      echo "$iface: endpoint $pub:$port (public)"
    }

    ${lib.concatMapStringsSep "\n"
      (e: ''configure ${e.interface} "${e.publicKey}" ${toString e.port} ${e.lanHost} ${e.publicHost}'')
      cfg}
  '';
in
{
  options.family.wgEndpoint = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        interface = lib.mkOption {
          type = lib.types.str;
          description = "WireGuard interface carrying this peer.";
        };
        publicKey = lib.mkOption {
          type = lib.types.str;
          description = "Public key of the peer whose endpoint should be re-targeted.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "The peer's listen port.";
        };
        lanHost = lib.mkOption {
          type = lib.types.str;
          description = ''
            Address to try first: where this peer lives on the home LAN. Per peer, not
            per interface -- sulfur's wgadm carries both hydrogen (10.0.0.10) and the
            router (10.0.0.1), and probing one address for both would leave whichever
            lost the coin toss unreachable at home.
          '';
        };
        publicHost = lib.mkOption {
          type = lib.types.str;
          description = "Address or name to fall back to when the LAN probe fails.";
        };
      };
    });
    default = [ ];
    description = ''
      WireGuard peers whose endpoint should follow this host between the home LAN and
      the outside world.
    '';
  };

  config = lib.mkIf (cfg != [ ]) {
    systemd.services = {
      wg-endpoint = {
        description = "Point WireGuard endpoints at the LAN or public address";

        # After the tunnels EXIST, not merely after the network does: the boot run used to
        # find no interface and return early, leaving the bootstrap LAN literal in place
        # until the 2-minute timer fired. Both kinds are named -- wg-quick on the laptops,
        # ensure-profiles on sulfur -- and ordering against an absent unit is a no-op.
        after = [ "network-online.target" "NetworkManager-ensure-profiles.service" ] ++ wgQuickUnits;
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = script;
        };
      };
    }
    # wg-quick's unit is a oneshot, so a failed bring-up stays failed forever and nobody
    # notices a dead unit on a child's laptop. Retry instead.
    //
    # Only for interfaces wg-quick actually builds. sulfur's wgadm is a NetworkManager
    # profile now (hosts/sulfur.nix) and has no wg-quick unit at all -- without this
    # filter we would declare systemd.services.wg-quick-wgadm carrying a serviceConfig
    # and no ExecStart, which is a broken unit describing a tunnel nobody starts that
    # way. NM does its own retrying for the profiles it owns.
    lib.listToAttrs (map (e: lib.nameValuePair "wg-quick-${e.interface}" {
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = 10;
      };
    }) (lib.filter (e: config.networking.wg-quick.interfaces ? ${e.interface}) cfg));

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
