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
}
