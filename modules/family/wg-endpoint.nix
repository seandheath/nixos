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

      # Try the peer's LAN address first, UNCONDITIONALLY -- no "am I on 10.0.0.0/24?"
      # test. That test was wrong: the kids' laptops live on the router's Kids VLAN
      # (10.20.0.0/24) and reach hydrogen through a pinhole, so they never hold a
      # 10.0.0.x address and would have skipped straight to the public endpoint -- which
      # arrives at our own WAN address from the inside and is not DNAT'd. No hairpin, no
      # tunnel, no services, for exactly the machines this exists to serve.
      #
      # Probing is the honest test anyway: a foreign network that happens to use the
      # same subnet cannot complete a WireGuard handshake with hydrogen's key.
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

        # After the tunnels exist, not merely after the network does. The boot run used
        # to start in the same second as wg-quick, find no interface, and return early
        # from every configure() call -- so the endpoint kept its bootstrap LAN literal
        # until the OnBootSec=2min timer fired. Away from home that is two minutes of a
        # tunnel dialling 10.0.0.10, which is someone else's machine.
        #
        # Both kinds of tunnel are named: wg-quick units on the kids' laptops, and
        # NetworkManager-ensure-profiles on sulfur, where wgQuickUnits is now empty.
        # Ordering against a unit a given host does not have is a harmless no-op.
        after = [ "network-online.target" "NetworkManager-ensure-profiles.service" ] ++ wgQuickUnits;
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = script;
        };
      };
    }
    # wg-quick's unit is a oneshot: if bringing the interface up fails for any reason it
    # stays failed forever, and on a child's laptop nobody is going to notice a dead
    # systemd unit. Retry instead. (The usual cause -- a hostname endpoint that could not
    # be resolved at boot -- is gone now that the configured endpoint is an IP literal,
    # but "no tunnel until an adult intervenes" is a bad enough failure mode to defend
    # against twice.)
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
