# hydrogen: the 24/7 server. Services, backups, and the couch Minecraft box.
{ config, pkgs, lib, ... }:
let
  devices = import ../modules/family/devices.nix;
in
{
  imports = [
    ../hardware/hydrogen.nix
    ../modules/gnome.nix
    ../modules/audio.nix
    ../modules/nix-ld.nix
    ../modules/core.nix
    ../modules/impermanence-server.nix
    ../modules/reverse-proxy.nix
    ../modules/nextcloud.nix
    ../modules/immich.nix
    ../modules/calibre.nix
    ../modules/paperless.nix
    ../modules/scanner.nix
    ../modules/ollama.nix
    ../modules/ai-marketplace-monitor.nix
    ../modules/backup.nix
    ../modules/git-server.nix
    ../modules/minecraft-server.nix
    ../modules/minecraft-servers.nix      # extra worlds on demand, in rootless podman
    ../modules/minecraft-couch.nix
    ../modules/minecraft-client.nix
    ../modules/valheim-server.nix
  ];

  networking.hostName = "hydrogen";
  system.stateVersion = "25.11";

  fleet.bootGenerations = 20;
  fleet.tailscaleClient = {
    enable = true;
    tags = [ "tag:server" ];
    authKeyFile = config.sops.secrets.tailscale-auth-hydrogen.path;
    # Headscale policy distinguishes administrative and family clients.
    allowedTCPPorts = [ 22 80 443 25565 21115 21116 21117 21118 21119 ];
    allowedUDPPorts = [ 2456 2457 2458 21116 ];
  };
  sops.secrets.tailscale-auth-hydrogen = { };
  # For diagnosing the transient btrfs csum failures; RAM is the prime suspect.
  boot.loader.systemd-boot.memtest86.enable = true;

  services.minecraftClient = {
    enable = true;
    # The couch pre-launcher passes --name and --server per player, and the entry point
    # here is "Minecraft (Couch)", not a single-player launcher.
    desktopEntry = false;
    # The restore copy: client and server closures mirrored into a local binary cache and
    # picked up by the nightly borg run. Survives Mojang or Modrinth dropping a version.
    archiveDir = "/var/lib/minecraft-archive";
  };

  # Private git remotes, bare repos owned by the `git` account. Headscale policy and
  # key-only SSH protect the control channel.
  fleet.gitServer.enable = true;

  # The fleet's flake.lock is bumped and gated here, on the only host that is always up.
  # One writer only -- a second is a push race. see CHANGELOG 2026-08-19
  fleet.lockUpdate.enable = true;

  # On-demand worlds alongside the shared one. Each launcher has a dedicated SOPS-managed
  # key; the public halves below are restricted to the forced Minecraft control command.
  fleet.minecraftServers = {
    enable = true;
    authorizedKeys =
      [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILxJG3+Zq8fSH/PG8cL3g1WQikuWE7U9XZCRsaSE9DgN minecraft-control-sulfur" ]
      ++ map (device: device.minecraftControlPublicKey) (builtins.attrValues devices.family);
  };

  services.familyValheim.enable = true;

  # Static br0. Plain false, not mkDefault, to beat the generated hardware file.
  networking.useDHCP = false;
  networking.bridges."br0".interfaces = [ "enp0s31f6" ];
  networking.interfaces.br0.ipv4.addresses = [{
    address = "10.0.0.10";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "10.0.0.1" ];

  # mkForce because the NetworkManager module defines wireless.enable outright rather than
  # as a default, and GNOME pulls NM in. No wifi on this host.
  networking.wireless.enable = lib.mkForce false;

  # NM off: scripted networking.bridges already owns br0, and two owners for one interface
  # is the class of bug behind the 2026-08-13 outage. NM held no profiles here and is not
  # the DNS source. See CHANGELOG 2026-08-13.
  networking.networkmanager.enable = lib.mkForce false;

  # THE ACCESS BOUNDARY -- read before changing any port. Headscale policy grants
  # admins direct access and limits family devices to the home service ports. The
  # LAN firewall admits subnet-routed traffic only from the router's SNAT address.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ ];
  networking.firewall.allowedUDPPorts = [ ];

  # Keep firewall ownership explicit; 22 is available on br0 for recovery and on
  # tailscale0 through fleet.tailscaleClient above.
  services.openssh.openFirewall = false;

  # sshd on the LAN, key-only, remains the recovery path if Tailscale is unavailable.
  # The router does not forward 22, so this widens reach to the house, not the Internet.
  networking.firewall.interfaces."br0".allowedTCPPorts = [ 22 ];

  # Subnet-routed clients are SNATed to the router's LAN address. Admit only
  # that source to ordinary home services; Marketplace instead uses hydrogen's
  # direct tail address so policy can keep it administrative.
  networking.firewall.extraCommands = lib.mkAfter ''
    iptables -N tailscale-lan-input 2>/dev/null || true
    iptables -F tailscale-lan-input
    iptables -A tailscale-lan-input -s 10.0.0.1 -p tcp -m multiport --dports 80,443,25565:25575 -j ACCEPT
    iptables -A tailscale-lan-input -s 10.0.0.1 -p udp -m multiport --dports 2456:2458 -j ACCEPT
    iptables -A tailscale-lan-input -j RETURN
    iptables -C nixos-fw -j tailscale-lan-input 2>/dev/null || iptables -I nixos-fw 1 -j tailscale-lan-input
  '';
  networking.firewall.extraStopCommands = lib.mkAfter ''
    iptables -D nixos-fw -j tailscale-lan-input 2>/dev/null || true
    iptables -F tailscale-lan-input 2>/dev/null || true
    iptables -X tailscale-lan-input 2>/dev/null || true
  '';

  services.openssh = {
    enable = true;
    # Key-only because 22 also remains reachable from the home LAN as a recovery path.
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "no";
  };

  # The monitor itself stays on loopback; nginx gives it the fleet wildcard certificate.
  # Unlike the other web apps, its config editor and live browser are administrative.
  fleet.vhosts.marketplace = {
    port = 8467;
    # Tailscale clients reach this vhost on hydrogen's direct tail address;
    # Headscale policy permits admins but not tag:family.
    allowedCIDRs = [ "100.64.0.0/10" ];
  };

  # The console is the recovery path here, per the br0 note above.
  fleet.accounts.rootPassword = "sops";
  fleet.accounts.sudoNoPassword = true;

  systemd.tmpfiles.rules = [
    "d /data/games 0755 sheath sheath -"
  ];

  environment.systemPackages = with pkgs; [
    rustdesk-flutter
    rustup firefox git curl wget htop tree ripgrep srm
    # /data is RAID0 with no redundancy and both devices carry btrfs corruption_errs;
    # btrfs can detect corruption there but never repair it.
    smartmontools
    vlc p7zip neovim tmux rsync go
  ];

  services.xserver.enable = true;
  virtualisation.libvirtd.enable = true;
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "sheath";

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

  # Xeon E-2176M with HWP, mains-powered 24/7; the balanced EPP leaves frames on the table
  # under four Minecraft clients plus the server.
  powerManagement.cpuFreqGovernor = "performance";

  # Pinned rather than tracking the stateVersion default, so a stateVersion bump cannot
  # silently trigger another major migration.
  services.postgresql.package = pkgs.postgresql_17;

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;
  hardware.enableRedistributableFirmware = true;
  # Closed modules: the safe choice for a pre-Turing GPU.
  hardware.nvidia.open = false;
  # legacy_580, NOT production: R580 is the last branch supporting Pascal. A pin to a
  # moving branch name pins nothing -- production, stable and latest all crossed the 590
  # boundary on the same day and this card lost its driver. See CHANGELOG 2026-08-13.
  hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
}
