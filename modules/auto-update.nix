# Nightly unattended rebuild, on every host.
{ config, pkgs, lib, ... }:
let
  # The branch, derived rather than retyped. flake.nix's input URL is the only place a
  # branch is named; a second copy here is what let the fleet sit six weeks past 25.11's
  # EOL, rebuilding nightly and reporting success the whole time.
  orig = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.nixpkgs.original;
  branch = "${orig.type}:${orig.owner}/${orig.repo}/${orig.ref}";

  notify = pkgs.writeShellScript "fleet-notify" ''
    # Deliver into every live session bus rather than guessing a username, so this works
    # unchanged on the kids' laptops. Every path ends in `|| true`: a broken notifier must
    # not turn one failed unit into two. The journal line is the record.
    for bus in /run/user/*/bus; do
      [ -S "$bus" ] || continue
      uid="$(basename "$(dirname "$bus")")"
      [ "$uid" -ge 1000 ] 2>/dev/null || continue
      user="$(${pkgs.coreutils}/bin/id -nu "$uid" 2>/dev/null)" || continue
      ${pkgs.util-linux}/bin/runuser -u "$user" -- \
        ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
        ${pkgs.libnotify}/bin/notify-send -u critical "$1" "$2" || true
    done
  '';

  # A frozen branch, dead DNS, or a run that quietly did nothing all exit 0, so OnFailure
  # cannot see them. Check the result instead: system.nixos.version embeds the nixpkgs
  # revision date (26.11.20260813.0e251e2).
  maxAgeDays = 21;
  staleCheck = pkgs.writeShellScript "check-nixpkgs-age" ''
    rev_date="$(echo "${config.system.nixos.version}" | ${pkgs.gnused}/bin/sed -n 's/^[0-9.]*\.\([0-9]\{8\}\)\..*$/\1/p')"
    [ -n "$rev_date" ] || exit 0
    age=$(( ( $(${pkgs.coreutils}/bin/date +%s) - $(${pkgs.coreutils}/bin/date -d "$rev_date" +%s) ) / 86400 ))
    if [ "$age" -gt ${toString maxAgeDays} ]; then
      echo "nixpkgs is $age days old (rev $rev_date) -- the branch may be frozen or unreachable" >&2
      ${notify} "System updates have stalled" \
        "${config.networking.hostName} is running nixpkgs from $rev_date, $age days old."
    fi
  '';
in
{
  system.autoUpgrade = {
    enable = true;
    # The repo, not a local checkout. A checkout nothing pulls means nixpkgs advances
    # nightly while the configuration never does.
    flake = "github:seandheath/nixos#${config.networking.hostName}";
    # Resolves the branch tip each run (NixOS adds --refresh), which is what delivers
    # security updates. Only nixpkgs is refreshed; the other inputs stay at flake.lock
    # until a deliberate `nu`.
    flags = [ "--override-input" "nixpkgs" branch "--no-write-lock-file" "-L" ];
    dates = "04:00";
    randomizedDelaySec = "45min";
  };

  systemd.services.nixos-upgrade = {
    onFailure = [ "nixos-upgrade-notify.service" ];
    serviceConfig.ExecStartPost = staleCheck;
  };

  systemd.services.nixos-upgrade-notify = {
    description = "Report a failed nixos-upgrade";
    serviceConfig.Type = "oneshot";
    script = ''
      echo "nixos-upgrade FAILED on ${config.networking.hostName}" >&2
      ${notify} "Automatic system update failed" \
        "${config.networking.hostName} could not rebuild. Run: journalctl -u nixos-upgrade -e"
    '';
  };

  # The catch-up case, and the common one: a laptop that was off at 04:00 runs the
  # persistent timer during boot and fails before any session exists to be notified.
  systemd.user.services.nixos-upgrade-failed-notify = {
    description = "Warn at login if the last nixos-upgrade failed";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      if ${pkgs.systemd}/bin/systemctl is-failed --quiet nixos-upgrade.service; then
        ${pkgs.libnotify}/bin/notify-send -u critical \
          "Automatic system update failed" \
          "${config.networking.hostName} could not rebuild. Run: journalctl -u nixos-upgrade -e" \
          || true
      fi
    '';
  };
}
