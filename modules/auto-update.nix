{ config, pkgs, lib, ... }: {
  # Automatic system updates with smart reboot notifications
  system.autoUpgrade = {
    enable = true;
    flake = "path:${config.users.users.sheath.home}/nixos/#${config.networking.hostName}";
    # --override-input resolves nixpkgs against the upstream ref at build time
    # without touching flake.lock, replacing the deprecated --update-input form.
    #
    # KEEP THIS BRANCH IN SYNC WITH nixpkgs.url IN flake.nix. It said nixos-25.11 for
    # six weeks after that branch went EOL on 2026-06-30, and the failure mode is worth
    # spelling out because nothing reports it: the job keeps succeeding. A frozen branch
    # still evaluates and still builds, so every host here rebuilt nightly, cheerfully,
    # against a tree that had stopped receiving security backports. What surfaced it was
    # not the update system but Signal Desktop hard-expiring 90 days after release.
    #
    # After the 26.05 migration the drift would have been worse than stale: this
    # override beats flake.lock, so a nightly run would have pulled the whole fleet
    # back onto EOL nixpkgs while the lock said otherwise -- silently undoing the
    # migration on five of six hosts, four of them the kids' laptops where nobody is
    # watching the output.
    flags = [
      "--override-input"
      "nixpkgs"
      "github:nixos/nixpkgs/nixos-26.05"
      "--no-write-lock-file"
      "-L"
    ];
    dates = "04:00";          # Run at 4 AM daily
    randomizedDelaySec = "45min";
  };
}
