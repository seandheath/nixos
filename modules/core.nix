# Base system config for hydrogen (the only host that imports this module):
# admin CLI tooling + sudo policy.
{ config, pkgs, lib, ... }:
{
  # Passwordless sudo for sheath. SECURITY: any process running as sheath, or a
  # compromised SSH key, gets root with no password prompt. Scoped to hydrogen
  # (this module) only. Enables unattended remote administration.
  security.sudo.extraRules = [
    {
      users = [ "sheath" ];
      commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
    }
  ];

  environment.systemPackages = with pkgs; [
    pv
    progress
    neovim
    wormhole-william
    git
    curl
    wget
    htop
    btop
    tree
    pciutils
    p7zip
    openssl
    pkg-config
    graphviz
    nmap
    unzip
    go
    rustup
    srm
    ripgrep
    gcc
    tmux
    nixpkgs-fmt
    niv
  ];
}
