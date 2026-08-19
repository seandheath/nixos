# Mullvad, pinned to settings that cannot cut the machine off the network.
{ config, pkgs, lib, ... }:

let
  cli = "${config.services.mullvad-vpn.package}/bin/mullvad";

  # Every setting is re-asserted rather than set once: an upgrade migrates settings.json and
  # what comes back out is not what went in. see CHANGELOG 2026-08-19
  assertSettings = pkgs.writeShellApplication {
    name = "mullvad-assert-settings";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
    text = ''
      deadline=$(( SECONDS + 60 ))
      until ${cli} status >/dev/null 2>&1; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "mullvad daemon never answered on its management socket" >&2
          exit 1
        fi
        sleep 1
      done

      # Read before writing, so the journal stays silent unless something actually drifted --
      # a line in this unit then means the daemon changed a setting behind us. An unparseable
      # value counts as drift: a reworded CLI must fail towards enforcing, not away from it.
      value() { awk -F': ' 'NR == 1 { print tolower($NF) }' | tr -d '[:space:]'; }

      if [ "$(${cli} lockdown-mode get | value)" != "off" ]; then
        echo "WARNING: lockdown mode was on -- forcing off" >&2
        ${cli} lockdown-mode set off
        # The daemon holds its Blocked policy until the tunnel state is touched, so clearing
        # the setting alone leaves the machine offline.
        ${cli} disconnect
      fi

      if [ "$(${cli} auto-connect get | value)" != "off" ]; then
        echo "auto-connect had drifted on -- forcing off" >&2
        ${cli} auto-connect set off
      fi

      if [ "$(${cli} lan get | value)" != "allow" ]; then
        echo "LAN sharing had drifted -- forcing allow" >&2
        ${cli} lan set allow
      fi

      # 1.1.1.1 alone. Mullvad rewrites resolv.conf to exactly the listed servers, in order,
      # and the home router is reachable only through a tunnel -- glibc has no notion of an
      # unreachable nameserver, only a slow one, so it would eat a 5s timeout per lookup. A
      # resolver whose reachability depends on a tunnel must never be first in resolv.conf.
      # Cost: the router's ad filtering while connected. The split-horizon names still resolve
      # from networking.hosts, which nsswitch reads first.
      dns="$(${cli} dns get)"
      servers="$(printf '%s' "$dns" | awk '/^[0-9a-fA-F.:]+$/ { print }' | paste -sd, -)"
      if [ "$(printf '%s' "$dns" | value)" != "yes" ] || [ "$servers" != "1.1.1.1" ]; then
        echo "DNS had drifted (servers: $servers) -- forcing 1.1.1.1" >&2
        ${cli} dns set custom 1.1.1.1
      fi
    '';
  };

  unblock = pkgs.writeShellApplication {
    name = "mullvad-unblock";
    runtimeInputs = [ pkgs.systemd pkgs.nftables pkgs.jq pkgs.coreutils ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "run as root: sudo mullvad-unblock" >&2
        exit 1
      fi

      blocked() {
        ${cli} status --json 2>/dev/null | jq -e '(.state == "error")
          or ((.details | type == "object") and (.details.locked_down == true))' >/dev/null
      }

      if systemctl is-active --quiet mullvad-daemon; then
        ${cli} lockdown-mode set off || true
        ${cli} disconnect || true
      fi

      if ! systemctl is-active --quiet mullvad-daemon || blocked; then
        # The daemon's nftables rules outlive the daemon; with it dead nothing else undoes them.
        if nft list table inet mullvad >/dev/null 2>&1; then
          nft delete table inet mullvad
        fi
        systemctl restart mullvad-daemon
      fi

      ${cli} status || true
    '';
  };
in
{
  services.mullvad-vpn.enable = true;

  environment.systemPackages = [ unblock ];

  systemd.services.mullvad-configure = {
    description = "Assert Mullvad settings the daemon may have migrated";
    after = [ "mullvad-daemon.service" ];
    requires = [ "mullvad-daemon.service" ];
    partOf = [ "mullvad-daemon.service" ];
    # Two events, no schedule. The daemon pulls it in on every start, because the settings it
    # re-reads on the way up are the ones that block the link; the generation label re-runs it
    # on every `nixos-rebuild switch`, so an update always lands on the declared state.
    wantedBy = [ "mullvad-daemon.service" "multi-user.target" ];
    restartTriggers = [ config.system.nixos.label ];
    serviceConfig = {
      Type = "oneshot";
      # Stays active so a generation switch sees a changed *running* unit and restarts it; an
      # inactive oneshot is not reliably re-run.
      RemainAfterExit = true;
      ExecStart = "${assertSettings}/bin/mullvad-assert-settings";
    };
  };
}
