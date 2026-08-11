# Which nixpkgs channel this host was built from.
#
# Set by mkHost in flake.nix -- the same argument that selects the nixpkgs and
# home-manager inputs -- so the value here cannot disagree with what the system was
# actually evaluated against. Nothing else should ever define it.
#
# It exists because modules/auto-update.nix has to name an input on the command line
# at 04:00 and there is no way to ask the running system which one it came from.
{ lib, ... }:

{
  options.fleet.channel = lib.mkOption {
    type = lib.types.enum [ "stable" "unstable" ];
    description = ''
      The nixpkgs channel this host tracks. "stable" is the `nixpkgs` flake input
      (nixos-26.05, hydrogen only); "unstable" is `nixpkgs-unstable` (the five
      laptops). Read by modules/auto-update.nix to pick the --override-input target
      and branch for the nightly rebuild.
    '';
  };
}
