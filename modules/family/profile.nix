# The kids' laptop profile -- what modules/workstation.nix is for sheath's machines. A host
# that imports this declares only its hostname; username, peer address, sops key names and
# Minecraft handle all follow from it via modules/family/peers.nix.
#
# NOT workstation.nix, for three reasons that would each break: packages-desktop.nix is an
# adult desktop and a large closure to build four times; opencode/qwen-code decrypt secrets
# these machines deliberately cannot read; and dconf.nix hardcodes a per-user path that
# resolves to nothing for any other user.
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
    ../steam.nix
    ../minecraft-client.nix
    ./vpn-peer.nix
  ];

  options.family.minecraft = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Ship the pinned Minecraft client. Off since 2026-08-07 until an install is known
      good: the payload is ~500 MiB of fixed-output derivations fetched from Mojang and
      Modrinth, and a laptop that cannot complete that fails the whole nixos-install.
      Install without it, then push from sulfur with `nixos-rebuild --target-host`, which
      copies the paths over SSH and never contacts Mojang.
    '';
  };

  options.family.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Marks a family-managed device, as opposed to one of sheath's own.";
  };

  config = {
    family.enable = true;
    system.stateVersion = "25.11";

    # These machines leave the house and are not disk-encrypted, so they carry the FAMILY
    # age key and can decrypt only family.yaml -- never the Nextcloud admin password, the
    # Borg key or the fleet VPN key. install.sh places the right key per host.
    sops.defaultSopsFile = lib.mkForce ../../secrets/family.yaml;

    # neededForUsers decrypts before accounts are created, which is the only way a
    # declarative password can come from sops. Escape hatch if activation ever fails here:
    # users.mutableUsers = true plus `passwd`.
    sops.secrets."${username}-password-hash".neededForUsers = true;

    users.users.${username} = {
      isNormalUser = true;
      description = username;
      # wheel: the kids administer their own machines, with a password prompt. It does not
      # weaken content filtering -- that is the router, per SSID -- but it does hand over
      # the machine, including sheath's age key, which decrypts family.yaml. See the open
      # item in docs/CHANGELOG.md about no longer sharing that hash.
      extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" ];
      hashedPasswordFile = config.sops.secrets."${username}-password-hash".path;
    };
    users.groups.${username} = { };


    # root stays locked (fleet.accounts.rootPassword defaults to "none"): administration is
    # sheath over SSH plus this rule, for unattended pushes from sulfur.
    fleet.accounts.sudoNoPassword = true;

    # Key-only, unlike hydrogen: these accounts have child-chosen passwords and the machines
    # sit on untrusted networks. Reachable from the LAN and from sulfur over the family
    # tunnel, where hydrogen forwards port 22 and nothing else.
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    networking.firewall.allowedTCPPorts = [ 22 ];

    programs.firefox.enable = true;

    environment.systemPackages = with pkgs; [
      vscodium
      libreoffice-fresh
      google-chrome
      klavaro          # touch-typing tutor: structured courses, adaptivity, games
      keepassxc        # database lives in Nextcloud, synced by the client below
      nextcloud-client
    ];

    # Gated here rather than by a conditional import -- the module system forbids reading
    # `config` from `imports`. Harmless: with enable = false nothing references the
    # derivation, so the 500 MiB payload never enters the closure.
    services.minecraftClient = {
      enable = config.family.minecraft;
      playerName = self.minecraftName;
      server = "mc.luckyobserver.com:25565";
    };

    # System-wide rather than home-manager: the kids have no home-manager config. The flake
    # path is absolute because a child's $HOME/nixos does not exist, and they need no read
    # access to it -- nixos-rebuild runs under sudo.
    programs.bash.interactiveShellInit = ''
      alias ns="nix search nixpkgs"
      alias dmesg="dmesg --color=always"

      # No `nu`: bumping inputs from a child's laptop would rewrite the fleet's lock.
      nr() { sudo nixos-rebuild switch --no-write-lock-file --flake /home/sheath/nixos#${hostName}; }
      nb() { sudo nixos-rebuild boot   --no-write-lock-file --flake /home/sheath/nixos#${hostName}; }
    '';

    networking.networkmanager.enable = true;
  };
}
