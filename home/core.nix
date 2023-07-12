{ config, pkgs, value,... }: {

  imports = [
    ./git.nix
    ./bash.nix
    ./alacritty.nix
    ./go.nix
  ];

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "sheath";
  home.homeDirectory = "/home/sheath";
  home.sessionPath = [
    "$HOME/go/bin/"
    "$HOME/.cargo/bin/"
    "$HOME/.local/bin/"
  ];
}
