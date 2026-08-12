{ config, pkgs, lib, ... }:
let
  # Two channels, two override targets. The INPUT NAME matters as much as the branch:
  # the fleet has both `nixpkgs` (stable, hydrogen) and `nixpkgs-unstable` (the five
  # laptops), and overriding the one a host does not build from is a no-op that still
  # exits 0. See the failure note below.
  channels = {
    stable = {
      input = "nixpkgs";
      branch = "github:nixos/nixpkgs/nixos-26.05";
    };
    unstable = {
      input = "nixpkgs-unstable";
      branch = "github:nixos/nixpkgs/nixos-unstable";
    };
  };
  channel = channels.${config.fleet.channel};
in
{
  # Automatic system updates with smart reboot notifications
  system.autoUpgrade = {
    enable = true;
    flake = "path:${config.users.users.sheath.home}/nixos/#${config.networking.hostName}";
    # --override-input resolves nixpkgs against the upstream ref at build time
    # without touching flake.lock, replacing the deprecated --update-input form.
    #
    # THE BRANCH AND INPUT NAME COME FROM fleet.channel (modules/fleet-channel.nix),
    # which mkHost in flake.nix sets from the same argument that picks the host's
    # nixpkgs input. Do not hardcode either here again. The reason is a failure mode
    # nothing reports: this file said nixos-25.11 for six weeks after that branch went
    # EOL on 2026-06-30, and the job kept succeeding the whole time. A frozen branch
    # still evaluates and still builds, so every host rebuilt nightly, cheerfully,
    # against a tree that had stopped receiving security backports. What surfaced it
    # was not the update system but Signal Desktop hard-expiring 90 days after release.
    #
    # The two-channel split adds a second way to fail silently in exactly the same
    # shape. This override BEATS flake.lock, so a laptop handed `--override-input
    # nixpkgs <stable>` would be dragged back onto 26.05 every night while the lock
    # said unstable -- and, because `nixpkgs` is still a real input of this flake, nix
    # would accept the flag and the job would report success. Deriving both halves
    # from fleet.channel is what makes that unrepresentable.
    flags = [
      "--override-input"
      channel.input
      channel.branch
      "--no-write-lock-file"
      "-L"
    ];
    dates = "04:00";          # Run at 4 AM daily
    randomizedDelaySec = "45min";
  };

  # ---------------------------------------------------------------------------
  # FAILURE REPORTING
  #
  # Nothing watches unit state on these machines. A failed nightly rebuild leaves a
  # red line in a journal nobody reads, which is the same shape as the six-week EOL
  # drift described above: the system was wrong and quiet about it. Now that the five
  # laptops track unstable with the kernel and nvidia driver unpinned, a failed
  # rebuild is an expected event rather than an alarming one -- so it has to be
  # visible, or the fleet silently stops updating.
  #
  # Two units, because one is not enough:
  #   - the system unit fires the moment the job fails, catching the case where
  #     somebody is sitting at the machine at 04:45.
  #   - the user unit re-checks at login, catching the far more common laptop case:
  #     the machine was off at 04:00, the timer is Persistent=true so the catch-up
  #     run happens during boot, and it fails BEFORE any graphical session exists to
  #     receive a notification. Without this half, the notification is theatre.
  # ---------------------------------------------------------------------------
  systemd.services.nixos-upgrade.onFailure = [ "nixos-upgrade-notify.service" ];

  systemd.services.nixos-upgrade-notify = {
    description = "Report a failed nixos-upgrade";
    serviceConfig.Type = "oneshot";
    script = ''
      echo "nixos-upgrade FAILED on ${config.networking.hostName} (${config.fleet.channel} channel)" >&2

      # Best effort only: every failure path here ends in `|| true`, because a broken
      # notification must never turn one failed unit into two. The journal line above
      # is the real record; the popup is a courtesy.
      #
      # Notifications have to be delivered INTO a session bus -- this unit is root
      # with no bus of its own. Walk the live per-user buses rather than guessing at
      # a username, so it works on the kids' laptops (where the logged-in user is not
      # sheath) without any per-host configuration.
      for bus in /run/user/*/bus; do
        [ -S "$bus" ] || continue
        uid="$(basename "$(dirname "$bus")")"
        # Skip system users; only real logins have a desktop to notify.
        [ "$uid" -ge 1000 ] 2>/dev/null || continue
        user="$(${pkgs.coreutils}/bin/id -nu "$uid" 2>/dev/null)" || continue
        ${pkgs.util-linux}/bin/runuser -u "$user" -- \
          ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
          ${pkgs.libnotify}/bin/notify-send -u critical \
            "Automatic system update failed" \
            "${config.networking.hostName} could not rebuild. Run: journalctl -u nixos-upgrade -e" \
          || true
      done
    '';
  };

  # Login-time catch-up. Deliberately reads systemd's own unit state instead of
  # writing a marker file: `is-failed` already survives for the life of the boot, and
  # a marker would need its own entry in modules/impermanence.nix to survive the
  # tmpfs root on sulfur -- state that can rot out of sync with reality.
  #
  # The trade-off, stated plainly: unit state does NOT survive a reboot, so a failure
  # at 04:45 on a machine that is later rebooted before anyone logs in goes unseen.
  # That is the residual gap. Closing it properly needs somewhere off-box to send to.
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
