{ config, pkgs, ... }:{
  environment.systemPackages = with pkgs; [
    go
    gopls
    dlv
    rustup
    bash-language-server
  ];

  programs.helix.enable = true;
  programs.helix.languages = [
    { auto-format = true; name = "rust"; }
    { auto-format = true; name = "go"; }
  ];
}
