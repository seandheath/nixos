# The kids' laptop profile -- what modules/workstation.nix is for sheath's machines. A host
# that imports this declares only its hostname; username and Minecraft handle follow from
# modules/family/devices.nix.
#
# NOT workstation.nix, for three reasons that would each break: packages-desktop.nix is an
# adult desktop and a large closure to build four times; opencode/qwen-code decrypt secrets
# these machines deliberately cannot read; and dconf.nix hardcodes a per-user path that
# resolves to nothing for any other user.
{ config, lib, pkgs, ... }:
let
  devices = import ./devices.nix;
  hostName = config.networking.hostName;
  self = devices.family.${hostName} or (throw ''
    modules/family/profile.nix: no entry for host "${hostName}" in modules/family/devices.nix.
  '');

  # username == hostName == the sops key prefix == the Minecraft handle, lowercased.
  # One string, everywhere. Its password and enrollment secrets are in family.yaml.
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
    ../minecraft-launcher.nix
  ];

  options.family.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Marks a family-managed device, as opposed to one of sheath's own.";
  };

  config = {
    family.enable = true;
    fleet.provisioning.enable = true;
    fleet.tailscaleClient = {
      enable = true;
      tags = [ "tag:family" ];
      authKeyFile = config.sops.secrets."tailscale-auth-${hostName}".path;
    };
    sops.secrets."tailscale-auth-${hostName}" = { };
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
    # sit on untrusted networks. Headscale policy permits administrative access.
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

    services.minecraftClient = {
      enable = true;
      playerName = self.minecraftName;
      server = "mc.luckyobserver.com:25565";
    };

    services.minecraftLauncher = {
      enable = true;
      controlKeyFile = config.sops.secrets."minecraft-control-${username}".path;
    };
    sops.secrets."minecraft-control-${username}" = {
      owner = username;
      mode = "0400";
    };

    # System-wide rather than home-manager: the kids have no home-manager config. Builds
    # from the repo rather than a checkout, which on these machines is sheath's and may not
    # exist or be current. --refresh because nix caches a github: ref for an hour.
    programs.bash.interactiveShellInit = ''
      alias ns="nix search nixpkgs"
      alias dmesg="dmesg --color=always"

      # No `nu`: bumping inputs from a child's laptop would rewrite the fleet's lock.
      nr() { sudo fleet-rebuild switch; }
      nb() { sudo fleet-rebuild boot; }
    '';

    networking.networkmanager.enable = true;
  };
}
