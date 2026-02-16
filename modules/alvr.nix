{ pkgs, ... }:

{
  programs.alvr = {
    enable = true;
    openFirewall = true;  # Opens TCP+UDP ports 9943 and 9944
  };

  # Fix "steam.desktop not writable" error when ALVR launches SteamVR
  # NixOS stores .desktop files in the read-only Nix store, so xdg-open
  # must go through the portal instead of modifying them directly
  xdg.portal.xdgOpenUsePortal = true;
}
