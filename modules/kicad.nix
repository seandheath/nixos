# Generated by pip2nix 0.8.0.dev1
# See https://github.com/nix-community/pip2nix

{ config, pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    kicad
    python3
    python3.pkgs.pip
  ];
}