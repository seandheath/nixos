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
    ../steam.nix
    ../minecraft-client.nix
    ./vpn-peer.nix
  ];

  options.family.minecraft = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Ship the pinned Minecraft client.

      DEFAULT IS OFF as of 2026-08-07, for all four laptops, until an install is known
      good. vizualwanderer's died fetching libraries.minecraft.net and the cause is not
      yet established -- most likely the AAAA record on a LAN with no working IPv6, or
      the asset derivation's 4403 parallel fetches. Debugging that is worth doing, but
      not while it is also the thing blocking every install.

      Flip this back to true once installs are stable, and push the result from sulfur
      with `nixos-rebuild --target-host` rather than letting each laptop fetch from
      Mojang itself -- sulfur already holds all 403 store paths.

      The payload is ~500 MiB fetched from Mojang and Modrinth as fixed-output
      derivations -- 115 libraries plus one FOD pulling 4403 asset objects in parallel --
      and a laptop that cannot complete that fails the whole `nixos-install`. Sulfur
      already holds the entire closure, so the reliable path is to install without it and
      then push the real configuration with `nixos-rebuild --target-host`, which copies
      those paths over SSH from sulfur's store and never contacts Mojang.

      That also sidesteps the kids' VLAN, where cache.nixos.org resolves to 0.0.0.0 and
      no fetch of any kind succeeds.
    '';
  };

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
      # wheel: the kids administer their own machines. sudo still prompts for their
      # password (security.sudo.wheelNeedsPassword defaults true) -- unlike sheath's
      # NOPASSWD rule below, which exists for unattended pushes from sulfur.
      #
      # WHAT THIS DOES AND DOES NOT GIVE AWAY. It does not weaken the content filtering:
      # that is enforced by the router, per SSID, and no amount of root on the laptop
      # changes which VLAN the wifi puts it on. It does hand over the machine itself --
      # they can disable their own tunnel, install things, and read any file on disk.
      #
      # Including /home/sheath/.config/sops/age/keys.txt, which decrypts
      # secrets/family.yaml. See the note above sheath's hashedPasswordFile.
      #
      # networkmanager so they can join wifi at a friend's house; video/audio/input for
      # the desktop and for game controllers.
      extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" ];
      hashedPasswordFile = config.sops.secrets."${username}-password-hash".path;
    };
    users.groups.${username} = { };

    # sheath comes from flake.nix's commonModules on every host, but with
    # mutableUsers = false an account with no declared password cannot log in at the
    # console at all -- and the console is the recovery path when the network is the
    # thing that is broken. The same hash is used on hydrogen and sulfur; it lives in
    # secrets/family.yaml because that file is readable by both age keys.
    #
    # WORTH RECONSIDERING NOW THAT THE KIDS HAVE WHEEL. The family age key sits at
    # /home/sheath/.config/sops/age/keys.txt on this machine, and root can read it. A
    # child with sudo can therefore decrypt secrets/family.yaml, which holds every
    # sibling's WireGuard key and password hash -- and THIS hash, which is also sheath's
    # password on hydrogen and sulfur. Offline cracking of one hash is the whole attack.
    #
    # The fix is to stop sharing it: give the laptops their own admin hash, so a child
    # who reads this file learns a password that works on four laptops they already have
    # root on, and nothing else.
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
    #
    # Imported unconditionally and gated here rather than by a conditional import: the
    # module system forbids referencing `config` from `imports` (infinite recursion, and
    # it says so by name). That is fine -- the module only declares its package as an
    # option default, so with enable = false nothing references the derivation and the
    # 500 MiB payload never enters the closure.
    services.minecraftClient = {
      enable = config.family.minecraft;
      playerName = self.minecraftName;
      server = "mc.luckyobserver.com:25565";
    };

    # ---------------------------------------------------------------------------
    # Shell helpers, matching sheath's (home/bash.nix).
    #
    # System-wide rather than home-manager: the kids have no home-manager config, and
    # these are useful to whoever is logged in. The flake path is absolute rather than
    # $HOME/nixos -- install.sh leaves the checkout in sheath's home, and a child's
    # $HOME/nixos does not exist. They do not need read access to it either, since
    # nixos-rebuild runs under sudo as root.
    programs.bash.interactiveShellInit = ''
      alias ns="nix search nixpkgs"
      alias dmesg="dmesg --color=always"

      # nr: switch now. nb: stage for next boot (kernel/bootloader changes).
      # Deliberately no `nu` -- bumping flake inputs from a child's laptop would
      # rewrite flake.lock for every host in the fleet.
      nr() { sudo nixos-rebuild switch --no-write-lock-file --flake /home/sheath/nixos#${hostName}; }
      nb() { sudo nixos-rebuild boot   --no-write-lock-file --flake /home/sheath/nixos#${hostName}; }
    '';

    # ---------------------------------------------------------------------------
    # Base system
    networking.networkmanager.enable = true;
    time.timeZone = "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";
  };
}
