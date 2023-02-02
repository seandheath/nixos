# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, nixpkgs, system, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
  nixpkgs.config = {
    packageOverrides = pkgs: {
      devel = import develTarball { config = config.nixpkgs.config; };
    };
  };
  time.timeZone = "America/New_York";
}
