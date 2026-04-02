{ config, pkgs, ... }: {
  programs.kitty = {
    enable = true;
    font.package = pkgs.b612;
    font.name = "B612 Mono";
    font.size = 11;
    settings = {
      shell = "bash --login";
    };
  };
}
