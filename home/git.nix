{ config, pkgs, ... }: {
  programs.git = {
    enable = true;
    userName = "Sean Heath";
    userEmail = "seanheath87@gmail.com";
    extraConfig = {
      pull.rebase = false;
    };
  };
}
