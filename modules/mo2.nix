# Mod Organizer 2 for Skyrim SE modding on NixOS
# Uses nix-gaming flake's mo2installer package
{ config, pkgs, lib, inputs, ... }:

{
  # nix-gaming.cachix.org substituter is configured centrally in
  # modules/nix-settings.nix (imported by all hosts).

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
