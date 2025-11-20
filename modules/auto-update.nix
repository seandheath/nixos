{ config, pkgs, lib, ... }: {
  # Automatic system updates with smart reboot notifications
  system.autoUpgrade = {
    enable = true;
    flake = "path:${config.users.users.sheath.home}/nixos/#${config.networking.hostName}";
    flags = [
      "--update-input"
      "nixpkgs"
      "--no-write-lock-file"
      "-L"
    ];
    dates = "04:00";          # Run at 4 AM daily
    randomizedDelaySec = "45min";
  };
}
