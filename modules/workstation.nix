{ config, pkgs, ... }:
{

  imports = [
    ./gnome.nix
    ./syncthing.nix
  ];

  environment.persistence."/nix/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/etc/NetworkManager/system-connections"
      "/var/log"
      "/var/lib/systemd/coredump"
      "/var/lib/bluetooth"
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "0750"; }
    ];
    files = [
      "/etc/machine-id"
    ];
    users.lo = {
      directories = [
        "Desktop"
        "Documents"
        "Downloads"
        "Music"
        "Pictures"
        "Public"
        "Templates"
        "Videos"
        "Sync"
        "vms"
        "workspace"
        "go"
        ".mozilla"
        ".steam"
        ".cargo"
	".rustup"
	".vscode-oss"
        { directory = ".gnupg"; mode = "0700"; }
        { directory = ".ssh"; mode = "0700"; }
        { directory = ".nixops"; mode = "0700"; }
        { directory = ".local/share/keyrings"; mode = "0700"; }
        ".local/share/direnv"
        ".local/share/Steam"
        ".local/share/vulkan"
        ".config/syncthing"
        ".config/Signal"
        ".config/VSCodium"
        ".config/Bitwarden"
        ".config/coc"
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    rtorrent
    nmap
    p7zip
    pkg-config
    unzip
    graphviz
    go
    rustup
    thefuck
    srm
    ripgrep
    gcc
    pandoc
    tectonic
    tmux
    nixpkgs-fmt
    direnv
  ];

  virtualisation = {
    oci-containers.backend = "podman";
    podman = {
      enable = true;
      dockerCompat = true;
    };
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };
  programs.steam.enable = true;
}

