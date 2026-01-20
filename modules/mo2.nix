# Mod Organizer 2 for Skyrim SE modding on NixOS
# Uses nix-gaming flake's mo2installer package
{ config, pkgs, lib, inputs, ... }:

{
  # Cachix for pre-built nix-gaming binaries
  nix.settings = {
    substituters = [ "https://nix-gaming.cachix.org" ];
    trusted-public-keys = [ "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4=" ];
  };

  environment.systemPackages = [
    # MO2 installer from nix-gaming flake
    inputs.nix-gaming.packages.${pkgs.stdenv.hostPlatform.system}.mo2installer

    # Wine-GE optimized for gaming (includes Proton patches)
    inputs.nix-gaming.packages.${pkgs.stdenv.hostPlatform.system}.wine-ge

    # Additional tools for MO2
    pkgs.jq              # JSON parsing for MO2 plugins
    pkgs.websocat        # Nexus SSO authentication
  ];

  # Steam extra compatibility tools path
  environment.sessionVariables = {
    STEAM_EXTRA_COMPAT_TOOLS_PATHS = "$HOME/.steam/root/compatibilitytools.d";
  };
}
