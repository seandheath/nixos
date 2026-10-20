# hydrogen: the 24/7 server. Services, backups, and the couch Minecraft box.
{ config, pkgs, lib, ... }:
let
  devices = import ../modules/family/devices.nix;
in
{
  imports = [
    # A fresh install may be on a different machine; prefer its detected hardware.
    (if builtins.pathExists ../provisioning/hydrogen/hardware.nix
     then ../provisioning/hydrogen/hardware.nix else ../hardware/hydrogen.nix)
    ../modules/gnome.nix
    ../modules/audio.nix
    ../modules/nix-ld.nix
    ../modules/persist-server.nix
    ../modules/reverse-proxy.nix
    ../modules/nextcloud.nix
    ../modules/immich.nix
    ../modules/calibre.nix
    ../modules/paperless.nix
    ../modules/scanner.nix
    ../modules/backup.nix
    ../modules/git-server.nix
    ../modules/gitea.nix
    ../modules/minecraft-server.nix
    ../modules/minecraft-servers.nix      # extra worlds on demand, in rootless podman
    ../modules/minecraft-couch.nix
    ../modules/minecraft-client.nix
    ../modules/valheim-server.nix
  ];

  system.stateVersion = "25.11";

  fleet.bootGenerations = 20;

  fileSystems."/backup" = {
    device = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_500GB_S5H7NJ0N419311D-part1";
    fsType = "btrfs";
    # nofail: a dead backup SSD must not block boot; the ssd Borg job requires the mount.
    options = [ "noatime" "compress=zstd" "nofail" ];
  };

  # Nightly fleet builds share the SSD with service data.
  nix.gc.dates = "daily";
  nix.settings = {
    min-free = 32 * 1024 * 1024 * 1024;
    max-free = 64 * 1024 * 1024 * 1024;
  };

  fleet.tailscaleClient = {
    enable = true;
    tags = [ "tag:server" ];
    acceptRoutes = false;
    authKeyFile = config.sops.secrets.tailscale-auth-hydrogen.path;
    # Headscale policy distinguishes administrative and family clients.
    allowedTCPPorts = [ 22 80 443 2222 25565 21115 21116 21117 21118 21119 ];
    allowedUDPPorts = [ 2456 2457 2458 21116 ];
  };
  sops.secrets.tailscale-auth-hydrogen = { };

  services.minecraftClient = {
    enable = true;
    # The couch pre-launcher passes --name and --server per player, and the entry point
    # here is "Minecraft (Couch)", not a single-player launcher.
    desktopEntry = false;
    # The restore copy: client and server closures mirrored into a local binary cache and
    # picked up by the nightly borg run. Survives Mojang or Modrinth dropping a version.
    archiveDir = "/var/lib/minecraft-archive";
  };

  # Legacy bare repositories remain separate from the fresh Gitea instance.
  fleet.gitServer.enable = true;
  fleet.gitServer.authorizedKeys = [ ]; # Legacy pushes remain disabled.

  # Here rather than in gitea.nix, which tests/gitea-vm.nix imports without the proxy.
  fleet.vhosts.git = {
    port = config.services.gitea.settings.server.HTTP_PORT;
    allowedCIDRs = [ "100.64.0.0/10" ];
  };
  # The runner and its containers need the same private endpoint as tailnet clients.
  networking.hosts.${devices.hydrogen.tailAddress} = [ "git.luckyobserver.com" ];
  sops.secrets.gitea-admin-password.sopsFile = ../secrets/gitea.yaml;
  fleet.gitea.adminPasswordFile = config.sops.secrets.gitea-admin-password.path;
  sops.secrets.gitea-actions-runner = { };
  sops.templates.gitea-actions-runner.content = "TOKEN=${config.sops.placeholder.gitea-actions-runner}\n";
  fleet.gitea.runnerTokenFile = config.sops.templates.gitea-actions-runner.path;

  # Publish candidates centrally; each machine builds before activating.
  fleet.lockUpdate.enable = true;
  system.autoUpgrade = {
    dates = "05:05";
    randomizedDelaySec = "5min";
    allowReboot = true;
    rebootWindow = { lower = "05:00"; upper = "06:00"; };
  };

  # On-demand worlds alongside the shared one. Each launcher has a dedicated SOPS-managed
  # key; the public halves below are restricted to the forced Minecraft control command.
  fleet.minecraftServers = {
    enable = true;
    listenAddress = devices.hydrogen.tailAddress;
    authorizedKeys =
      [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILxJG3+Zq8fSH/PG8cL3g1WQikuWE7U9XZCRsaSE9DgN minecraft-control-sulfur" ]
      ++ map (device: device.minecraftControlPublicKey) (builtins.attrValues devices.family);
  };

  services.familyValheim = {
    enable = true;
    listenAddress = devices.hydrogen.tailAddress;
  };

  # Static br0. Plain false, not mkDefault, to beat the generated hardware file.
  networking.useDHCP = false;
  networking.bridges."br0".interfaces = [ "enp48s0" ];
  networking.interfaces.br0.ipv4.addresses = [{
    address = "10.0.0.10";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "10.0.0.1" ];

  # Valheim publishes on the stable tail address. Permit the bind during the short boot
  # window before tailscaled restores that address to tailscale0.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # NM off: scripted networking.bridges already owns br0, and two owners for one interface
  # is the class of bug behind the 2026-08-13 outage. NM held no profiles here and is not
  # the DNS source. See CHANGELOG 2026-08-13.
  networking.networkmanager.enable = lib.mkForce false;

  # THE ACCESS BOUNDARY -- read before changing any port. Headscale policy grants
  # admins direct access and limits family devices to the declared service ports.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ ];
  networking.firewall.allowedUDPPorts = [ ];

  # Keep firewall ownership explicit; 22 is available on br0 for recovery and on
  # tailscale0 through fleet.tailscaleClient above.
  services.openssh.openFirewall = false;

  # sshd on the LAN, key-only, remains the recovery path if Tailscale is unavailable.
  # The router does not forward 22, so this widens reach to the house, not the Internet.
  networking.firewall.interfaces."br0".allowedTCPPorts = [ 22 ];

  services.openssh = {
    enable = true;
    # Key-only because 22 also remains reachable from the home LAN as a recovery path.
    settings.PasswordAuthentication = false;
    # Otherwise PAM still accepts passwords through keyboard-interactive.
    settings.KbdInteractiveAuthentication = false;
    settings.PermitRootLogin = "no";
  };

  # The console is the recovery path here, per the br0 note above.
  fleet.accounts.rootPassword = "sops";
  fleet.accounts.sudoNoPassword = true;

  systemd.tmpfiles.rules = [
    "d /data/games 0755 ${config.fleet.adminUser} ${config.fleet.adminUser} -"
  ];

  # /data is RAID0: scrub can only detect corruption there, which is still worth knowing.
  services.btrfs.autoScrub.fileSystems = [ "/data" "/backup" ];
  services.smartd.enable = true;
  services.fwupd.enable = true;
  zramSwap.enable = true;

  environment.systemPackages = with pkgs; [
    rustdesk-flutter
    rustup firefox git curl wget htop btop tree ripgrep srm pciutils openssl nmap unzip
    pv progress wormhole-william graphviz nixpkgs-fmt
    # /data is RAID0 with no redundancy and both devices carry btrfs corruption_errs;
    # btrfs can detect corruption there but never repair it.
    smartmontools
    vlc p7zip neovim tmux rsync go python3
  ];

  services.xserver.enable = true;
  virtualisation.libvirtd.enable = true;
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = config.fleet.primaryUser;

  # https://github.com/NixOS/nixpkgs/issues/103746 -- GNOME autologin needs these off.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # GNOME's power daemon idle-suspends independently of the masked targets below, and
  # RustDesk needs a live desktop on the eDP panel to capture.
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.settings-daemon.plugins.power]
    sleep-inactive-ac-type='nothing'
    sleep-inactive-battery-type='nothing'

    [org.gnome.desktop.screensaver]
    lock-enabled=false
    idle-activation-enabled=false

    [org.gnome.desktop.session]
    idle-delay=uint32 0
  '';
  services.desktopManager.gnome.extraGSettingsOverridePackages = [ pkgs.gnome-settings-daemon ];

  # RustDesk host, in the autologin session so it has the Wayland/DBus/portal environment
  # screen capture needs. Unattended password and direct-IP are set once in the app.
  # Direct tail access is permitted only to administrative clients by Headscale policy.
  systemd.user.services.rustdesk = {
    description = "RustDesk remote-desktop host";
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.rustdesk-flutter}/bin/rustdesk";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # An unnoticed suspend would take every service offline at once.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # ...and logind must never TRY: a masked target is not a graceful no, it is a livelock.
  # SleepOperation="" leaves it no candidate operation. See CHANGELOG 2026-08-04.
  services.logind.settings.Login = {
    IdleAction = "ignore";
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleSuspendKey = "ignore";
    HandleSuspendKeyLongPress = "ignore";
    HandleHibernateKey = "ignore";
    HandleHibernateKeyLongPress = "ignore";
    SleepOperation = "";
  };

  # i7-12700H with HWP, mains-powered 24/7; the balanced EPP leaves frames on the table
  # under four Minecraft clients plus the server.
  powerManagement.cpuFreqGovernor = "performance";

  # Pinned rather than tracking the stateVersion default, so a stateVersion bump cannot
  # silently trigger another major migration.
  services.postgresql.package = pkgs.postgresql_17;

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;
  hardware.enableRedistributableFirmware = true;
  # RTX 3070 Ti (Ampere): open modules, default driver branch.
  hardware.nvidia.open = true;
}
