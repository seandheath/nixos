{ config, pkgs, ... }: {
  programs.git = {
    enable = true;
    userName = "Sean Heath";
    userEmail = "heathsd@pm.me";
    extraConfig = {
      pull.rebase = false;
    };
  };
}
