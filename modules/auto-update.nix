# Nightly unattended rebuild, on every host. One host additionally owns the flake.lock the
# whole fleet builds -- see CHANGELOG 2026-08-19.
{ config, pkgs, lib, ... }:
let
  cfg = config.fleet.lockUpdate;

  remote = "git@github.com:seandheath/nixos";
  publicRemote = "https://github.com/seandheath/nixos.git";

  localRebuild = pkgs.writeShellApplication {
    name = "fleet-rebuild";
    runtimeInputs = [ pkgs.git pkgs.coreutils ];
    text = ''
      action="''${1:-switch}"
      case "$action" in switch|boot|build) ;; *) echo "usage: fleet-rebuild [switch|boot|build]" >&2; exit 2;; esac

      state="''${STATE_DIRECTORY:-/var/lib/nixos-upgrade}"
      repo="$state/checkout"
      provision=/persist/nixos-install
      host=${lib.escapeShellArg config.networking.hostName}

      for file in default.nix disk.nix hardware.nix; do
        [ -s "$provision/$file" ] || { echo "missing local provisioning file: $provision/$file" >&2; exit 1; }
      done

      if [ ! -d "$repo/.git" ]; then
        rm -rf -- "$repo"
        git clone --branch main ${lib.escapeShellArg publicRemote} "$repo"
      fi
      git -C "$repo" remote set-url origin ${lib.escapeShellArg publicRemote}
      git -C "$repo" fetch --prune origin main
      git -C "$repo" reset --hard origin/main
      git -C "$repo" clean -ffdx

      target="$repo/provisioning/$host"
      mkdir -p "$target"
      install -m 0600 "$provision/default.nix" "$provision/disk.nix" "$provision/hardware.nix" "$target/"
      exec ${config.system.build.nixos-rebuild}/bin/nixos-rebuild "$action" --flake "$repo#$host" -L
    '';
  };

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
  # revision date (26.11.20260813.0e251e2). Also the backstop for a wedged lock updater:
  # if the lock stops advancing, every host notices on its own.
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

  lockUpdate = pkgs.writeShellApplication {
    name = "nixos-lock-update";
    runtimeInputs = [ pkgs.git config.nix.package pkgs.openssh ];
    text = ''
      repo="''${STATE_DIRECTORY:-/var/lib/nixos-lock}/checkout"

      if [ ! -d "$repo/.git" ]; then
        rm -rf -- "$repo"
        git clone --branch main ${lib.escapeShellArg remote} "$repo"
      fi

      # A scratch pad, not a working tree. Anything left behind by an interrupted run --
      # a half-updated lock, a result symlink -- would otherwise be what gets pushed.
      git -C "$repo" remote set-url origin ${lib.escapeShellArg remote}
      git -C "$repo" fetch --prune origin main
      git -C "$repo" reset --hard origin/main
      git -C "$repo" clean -ffdx

      # nixpkgs alone. The other inputs stay deliberate (`nu`); they follow nixpkgs, so
      # they pick this up without being bumped themselves.
      nix flake update --flake "$repo" nixpkgs
      if git -C "$repo" diff --quiet -- flake.lock; then
        exit 0
      fi

      # The gate, and the reason this runs on one host rather than six: flake.nix's checks
      # are every host's toplevel plus the installer, so a nixpkgs revision that breaks any
      # machine in the fleet reaches none of them.
      nix flake check "$repo"

      git -C "$repo" -c user.name=hydrogen -c user.email=seanheath@gmail.com \
        commit -q -m "chore(flake): nightly nixpkgs update" -- flake.lock
      git -C "$repo" push -q origin main
      echo "pushed $(git -C "$repo" rev-parse --short HEAD)"
    '';
  };
in
{
  options.fleet.lockUpdate.enable = lib.mkEnableOption ''
    nightly nixpkgs bump of the fleet's flake.lock, gated on `nix flake check` and pushed to
    the repo every host builds. Exactly one host may own this -- a second writer is a push race
  '';

  config = lib.mkMerge [
    {
      system.autoUpgrade = {
        enable = true;
        # The repo, not a local checkout. A checkout nothing pulls means nixpkgs advances
        # nightly while the configuration never does.
        flake = "github:seandheath/nixos#${config.networking.hostName}";
        # The committed lock, nothing overridden. A nightly that resolves the branch tip
        # itself leaves the lock behind, which makes every hand-run rebuild a rollback of
        # however far the fleet has drifted. see CHANGELOG 2026-08-19
        flags = [ "-L" ];
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

    (lib.mkIf config.fleet.provisioning.enable {
      system.autoUpgrade.enable = lib.mkForce false;
      environment.systemPackages = [ localRebuild ];

      systemd.services.nixos-upgrade = {
        description = "Rebuild from the fleet configuration and local provisioning state";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "nixos-upgrade";
          ExecStart = "${localRebuild}/bin/fleet-rebuild switch";
          # A GitHub-placeholder preflight from a local customization cannot apply to the
          # assembled checkout; the rebuild script instead requires local facts above.
          ExecStartPre = lib.mkForce [ ];
        };
      };

      systemd.timers.nixos-upgrade = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "04:00";
          RandomizedDelaySec = "45min";
          Persistent = true;
        };
      };
    })

    (lib.mkIf cfg.enable {
      # Write access to the one repo, and nothing else on the account. Root-owned 0400 by
      # default, which is what the unit needs.
      sops.secrets.github-deploy-key = { };

      systemd.services.nixos-lock-update = {
        description = "Bump nixpkgs in the fleet's flake.lock";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        onFailure = [ "nixos-lock-update-notify.service" ];
        # 01:00: ahead of the 02:45 pg dumps, the 03:00 borg runs, and the fleet's 04:00
        # upgrade window, so a bump lands the same night it is made.
        startAt = "01:00";
        # `environment`, not serviceConfig.Environment: systemd splits an unquoted
        # Environment= on whitespace, and GIT_SSH_COMMAND is a command line.
        environment = {
          HOME = "/var/lib/nixos-lock";
          GIT_SSH_COMMAND =
            "ssh -i ${config.sops.secrets.github-deploy-key.path}"
            + " -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes";
        };
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "nixos-lock";
          ExecStart = "${lockUpdate}/bin/nixos-lock-update";
        };
      };

      # A missed night catches up rather than silently skipping a nixpkgs bump.
      systemd.timers.nixos-lock-update.timerConfig.Persistent = true;

      # Its own notifier, not nixos-upgrade's: this failure stalls the whole fleet, and
      # pointing at the wrong journal unit is what makes that take a day to find.
      systemd.services.nixos-lock-update-notify = {
        description = "Report a failed flake.lock update";
        serviceConfig.Type = "oneshot";
        script = ''
          echo "nixos-lock-update FAILED on ${config.networking.hostName}" >&2
          ${notify} "Fleet updates have stalled" \
            "The nightly nixpkgs bump did not pass. Run: journalctl -u nixos-lock-update -e"
        '';
      };
    })
  ];
}
