{ config, pkgs, ... }: {
  programs.git = {
    enable = true;
    settings = {
      user.name = "Sean Heath";
      user.email = "seanheath87@gmail.com";
      pull.rebase = false;
      init.defaultBranch = "main";
      # The private forge over SSH, so Cargo and Nix fetches of its HTTPS URLs
      # use the key instead of asking for a password.
      url."ssh://git@git.luckyobserver.com:2222/".insteadOf = "https://git.luckyobserver.com/";
    };
  };
}
