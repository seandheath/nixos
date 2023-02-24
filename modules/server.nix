{ config, pkgs, ... }:
{
  environment.persistence."/nix/persist" = {
    hideMounts = true;
    directories = [
      "/etc/ssh"
      "/var/log"
      "/var/lib/systemd/coredump"
    ];
    files = [
      "/etc/machine-id"
    ];
    users.lo = {
      directories = [
        "Sync"
        { directory = ".gnupg"; mode = "0700"; }
        { directory = ".ssh"; mode = "0700"; }
        { directory = ".nixops"; mode = "0700"; }
        { directory = ".local/share/keyrings"; mode = "0700"; }
        ".local/share/direnv"
        ".config/syncthing"
      ];
    };
  };

  environment.systemPackages = with pkgs; [
    tmux
    go
  ];
}

