{
  imports = [
    ../home/bash.nix
    ../home/alacritty.nix
    ../home/git.nix
    ../home/go.nix
    ../home/neovim.nix
  ];
  programs.home-manager.enable = true;
  home.stateVersion = "25.05";
}
