{ config, pkgs, lib, ... }:
{
  # Desktop Environment
  environment.systemPackages = with pkgs; [
    kicad
    (python3.withPackages kipart)
  ];
}

