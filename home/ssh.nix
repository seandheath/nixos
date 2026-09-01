{ config, lib, ... }:
let
  devices = import ../modules/family/devices.nix;
  personalIdentity = "~/.ssh/personal";

  # Only identities referenced by the SSH settings belong in the managed set.
  privateKeyFiles = [
    "id_cclaude"
    "id_ed25519"
    "personal"
  ];

  familyHosts = lib.mapAttrs (name: _: {
    HostName = "${name}.tail.luckyobserver.com";
    User = "sheath";
    IdentityFile = personalIdentity;
  }) devices.family;
in
{
  # sops-nix decrypts these into the user runtime directory and places 0400
  # symlinks at their original ~/.ssh paths. Only ciphertext enters the store.
  sops.secrets = lib.listToAttrs (map (fileName:
    lib.nameValuePair "ssh-private-key-${fileName}" {
      path = "${config.home.homeDirectory}/.ssh/${fileName}";
      mode = "0400";
    }
  ) privateKeyFiles);

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings = {
      "*" = {
        IdentitiesOnly = true;
        SetEnv.TERM = "xterm";
      };

      wifi = {
        HostName = "10.0.0.2";
        User = "danger";
        IdentityFile = personalIdentity;
        Port = 44;
      };

      elise = {
        User = "admin";
        IdentityFile = "~/.ssh/id_ed25519";
      };

      cecilia = {
        User = "admin";
        IdentityFile = "~/.ssh/id_ed25519";
      };

      xh = {
        HostName = "sunrise.nheath.com";
        User = "lo";
        IdentityFile = personalIdentity;
        Port = 2345;
      };

      hydrogen = {
        HostName = "hydrogen.tail.luckyobserver.com";
        User = "sheath";
        IdentityFile = personalIdentity;
        Port = 22;
        ServerAliveInterval = 300;
        ServerAliveCountMax = 2;
      };

      hydrogen-lan = {
        HostName = "10.0.0.10";
        User = "sheath";
        IdentityFile = personalIdentity;
      };

      "router nixrouter" = {
        HostName = "router.tail.luckyobserver.com";
        User = "admin";
        IdentityFile = personalIdentity;
        Port = 22;
        IPQoS = "none";
      };

      router-lan = {
        HostName = "10.0.0.1";
        User = "admin";
        IdentityFile = personalIdentity;
        IPQoS = "none";
      };

      hydrogen-git = {
        HostName = "hydrogen.tail.luckyobserver.com";
        User = "git";
        IdentityFile = personalIdentity;
      };

      "github.com" = {
        User = "git";
        IdentityFile = "~/.ssh/id_cclaude";
      };
    } // familyHosts;
  };
}
