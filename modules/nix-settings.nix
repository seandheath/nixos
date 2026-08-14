# Central Nix daemon settings: experimental features, binary caches,
# and automatic store maintenance. Imported by all hosts via commonModules
# in flake.nix so every machine shares one source of truth for caches/GC.
{ ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    download-buffer-size = 1073741824; # 1 GiB — avoids buffer-full stalls on big fetches

    # Binary caches (consolidated here so all substituters live in one place).
    # pebble: personal cachix.
    substituters = [
      "https://pebble.cachix.org"
    ];
    trusted-public-keys = [
      "pebble.cachix.org-1:aTqwT2hR6lGggw/rPISRcHZctDv2iF7ewsVxf3Hq6ow="
    ];

    # Deduplicate identical store paths as they are written (daemon-side).
    # Complements nix.optimise.automatic below, which sweeps existing paths.
    auto-optimise-store = true;
  };

  # Weekly garbage collection. Necessary because system.autoUpgrade
  # (modules/auto-update.nix) builds a new generation daily; without GC the
  # store grows without bound (bootloader configurationLimit only caps boot
  # entries, not store paths).
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Periodic hard-link dedup of the whole store (systemd timer). Pairs with
  # auto-optimise-store to reclaim space from paths written before it was on.
  nix.optimise.automatic = true;
}
