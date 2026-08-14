# Declarative accounts for sheath, on every host.
#
# mutableUsers = false is what makes a declared hash authoritative -- with the default,
# NixOS applies a declared password only when it CREATES the account, so setting
# hashedPasswordFile alone changes nothing on a running system. It also means declared
# state becomes the whole state, discarding any password set interactively at install.
#
# sheath's hash lives in secrets/family.yaml because that file is encrypted to the main key
# AND the family key, so all six hosts read one entry. root is per-host: the kids' laptops
# leave it locked deliberately.
{ config, lib, ... }:
let
  cfg = config.fleet.accounts;
in
{
  options.fleet.accounts = {
    rootPassword = lib.mkOption {
      type = lib.types.enum [ "none" "sops" "persist" ];
      default = "none";
      description = ''
        How root's password is declared. "none" leaves the account locked -- no console
        root login. "sops" where the console is the recovery path; a server that cannot be
        rescued from its own console is a bad trade for a tidier password story.
        "persist" reads /persist/secrets/root-password, for an impermanent host: sops
        needs the age key under /home, which is unavailable in exactly the case root
        recovery exists for.
      '';
    };
    sudoNoPassword = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Passwordless sudo for sheath, for unattended remote administration. SECURITY: any
        process running as sheath, or a compromised SSH key, is then root with no prompt.
      '';
    };
  };

  config = {
    users.mutableUsers = false;

    sops.secrets."sheath-password-hash" = {
      sopsFile = ../secrets/family.yaml;
      neededForUsers = true;
    };
    users.users.sheath.hashedPasswordFile =
      config.sops.secrets."sheath-password-hash".path;

    sops.secrets."root-password-hash" =
      lib.mkIf (cfg.rootPassword == "sops") { neededForUsers = true; };
    users.users.root.hashedPasswordFile = {
      none = null;
      sops = config.sops.secrets."root-password-hash".path;
      persist = "/persist/secrets/root-password";
    }.${cfg.rootPassword};

    security.sudo.extraRules = lib.mkIf cfg.sudoNoPassword [
      {
        users = [ "sheath" ];
        commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ];
      }
    ];
  };
}
