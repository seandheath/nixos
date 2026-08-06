# The kids' laptop profile -- what modules/workstation.nix is for sheath's machines.
#
# A host that imports this needs to declare almost nothing: which peer it is comes from
# networking.hostName via modules/family/peers.nix, and the username follows the
# hostname. See hosts/gentlemenpupil.nix for the whole of a family host file.
#
# WHY NOT JUST IMPORT workstation.nix. Three reasons, all of which would break:
#   - packages-desktop.nix is a 127-line adult desktop (Ghidra, Mullvad, Signal,
#     Discord, CAD, the RE stack). Wrong software for a nine-year-old and a large
#     closure to build four times.
#   - opencode.nix, qwen-code.nix and home/sheath.nix's Pi config decrypt openwebui-*
#     out of secrets/secrets.yaml, which these machines deliberately cannot read (they
#     carry the family age key -- see .sops.yaml).
#   - dconf.nix hardcodes /etc/profiles/per-user/sheath/bin/ptyxis in a keybinding,
#     which resolves to nothing for any other user.
#
# What they share with the workstations is imported by name below.
{ config, lib, pkgs, ... }:
let
  peers = import ./peers.nix;
  hostName = config.networking.hostName;
  self = peers.family.${hostName} or (throw ''
    modules/family/profile.nix: no entry for host "${hostName}" in modules/family/peers.nix.
  '');

  # username == hostName == the sops key prefix == the Minecraft handle, lowercased.
  # One string, everywhere. Its secrets are `wg-priv-<username>` (in peers.nix) and
  # `<username>-password-hash` (below), both in secrets/family.yaml.
  username = hostName;
in
{
  imports = [
    ../gnome.nix
    ../audio.nix
    ../bluetooth.nix
    ../printing.nix
    ../sops.nix
    ../auto-update.nix
    ../minecraft-client.nix
    ../steam.nix
    ./vpn-peer.nix
  ];

  options.family.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Set by modules/family/profile.nix on the machines it configures. Other modules
      read it to tell a family-managed device from one of sheath's own -- home/sheath.nix
      uses it to skip the home-manager secrets these hosts cannot decrypt.
    '';
  };

  config = {
    family.enable = true;

    # ---------------------------------------------------------------------------
    # Secrets
    #
    # These machines leave the house, are used by children, and are not disk-encrypted.
    # They therefore carry the FAMILY age key, not the main one, and can decrypt only
    # secrets/family.yaml -- never the Nextcloud admin password, the Borg repository
    # key or the fleet VPN SSH key. install.sh places the right key per host.
    sops.defaultSopsFile = lib.mkForce ../../secrets/family.yaml;

    # neededForUsers decrypts into /run/secrets-for-users *before* user accounts are
    # created, which is the only way a declarative password can come from sops. It is
    # the first use of this in the repo; if activation ever fails here, the escape hatch
    # is users.mutableUsers = true plus `passwd`, which is what the other hosts do.
    sops.secrets."${username}-password-hash".neededForUsers = true;
    sops.secrets."sheath-password-hash".neededForUsers = true;

    # ---------------------------------------------------------------------------
    # Accounts
    #
    # Declarative passwords are the point: a child cannot change their own password out
    # from under you, and a reinstall reproduces the same login.
    users.mutableUsers = false;

    users.users.${username} = {
      isNormalUser = true;
      description = username;
      # No wheel. networkmanager so they can join wifi at a friend's house; video/audio/
      # input for the desktop and for game controllers.
      extraGroups = [ "networkmanager" "video" "audio" "input" ];
      hashedPasswordFile = config.sops.secrets."${username}-password-hash".path;
    };
    users.groups.${username} = { };

    # sheath comes from flake.nix's commonModules on every host, but with
    # mutableUsers = false an account with no declared password cannot log in at the
    # console at all -- and the console is the recovery path when the network is the
    # thing that is broken. The same hash is used on hydrogen and sulfur; it lives in
    # secrets/family.yaml because that file is readable by both age keys.
    users.users.sheath.hashedPasswordFile = config.sops.secrets."sheath-password-hash".path;

    # root stays locked deliberately: no hashedPasswordFile, so no console root login.
    # Administration is sheath over SSH plus the sudo rule below.

    # SECURITY: any process running as sheath on these machines gets root without a
    # prompt. Same trade as modules/core.nix makes on hydrogen, for the same reason --
    # unattended remote administration. sheath's account here exists only for that.
    security.sudo.extraRules = [
      {
        users = [ "sheath" ];
        commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
      }
    ];

    # ---------------------------------------------------------------------------
    # Remote administration
    #
    # Key-only: unlike hosts/hydrogen.nix these accept no password, because the accounts
    # have child-chosen passwords and the machines sit on untrusted networks. sheath's
    # authorized key arrives via users/sheath.nix.
    #
    # Reachable from the LAN, and from sulfur over the family tunnel -- hydrogen forwards
    # exactly port 22 from sulfur and nothing else (modules/family/vpn-hub.nix).
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    networking.firewall.allowedTCPPorts = [ 22 ];

    # ---------------------------------------------------------------------------
    # Software
    programs.firefox.enable = true;

    environment.systemPackages = with pkgs; [
      vscodium
      libreoffice-fresh
      google-chrome
      klavaro          # touch-typing tutor: structured courses, adaptivity, games
      keepassxc        # database lives in Nextcloud, synced by the client below
      nextcloud-client
    ];

    # Same pinned client and mod set as sulfur and hydrogen's couch clients, so version
    # lockstep with the server is enforced by the assertions in modules/minecraft-client.nix
    # rather than by memory. Connects by name over the tunnel; 25565 is no longer
    # reachable from the LAN.
    services.minecraftClient = {
      enable = true;
      playerName = self.minecraftName;
      server = "mc.luckyobserver.com:25565";
    };

    # ---------------------------------------------------------------------------
    # Base system
    networking.networkmanager.enable = true;
    time.timeZone = "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";
  };
}
