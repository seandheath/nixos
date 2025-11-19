{ config, pkgs, ... }: {
  programs.git = {
    enable = true;
    settings = {
      user.name = "Sean Heath";
      user.email = "seanheath87@gmail.com";
      pull.rebase = false;
    };
  };
}
