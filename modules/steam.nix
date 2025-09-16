{ config, pkgs, ... }:{
  programs.gamescope.enable = true;
  programs.gamemode.enable = true;
  programs.steam = {
    enable = true;
    protontricks.enable = true;
  };
  environment.systemPackages = with pkgs; [
    (heroic.override { extraPkgs = pkgs: [ pkgs.gamescope ]; })
  ];
}
