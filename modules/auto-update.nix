{ config, pkgs, lib, ... }: {
  # Automatic system updates with smart reboot notifications
  system.autoUpgrade = {
    enable = true;
    flake = "path:${config.users.users.sheath.home}/nixos/#${config.networking.hostName}";
    # --override-input resolves nixpkgs against the upstream ref at build time
    # without touching flake.lock, replacing the deprecated --update-input form.
    # Keep this branch in sync with the nixpkgs.url in flake.nix.
    flags = [
      "--override-input"
      "nixpkgs"
      "github:nixos/nixpkgs/nixos-25.11"
      "--no-write-lock-file"
      "-L"
    ];
    dates = "04:00";          # Run at 4 AM daily
    randomizedDelaySec = "45min";
  };
}
