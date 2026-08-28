# hydrogen: the 24/7 server. Services, backups, and the couch Minecraft box.
{ config, pkgs, lib, ... }:
let
  peers = import ../modules/family/peers.nix;
in
{
  imports = [
    ../hardware/hydrogen.nix
    ../modules/gnome.nix
    ../modules/audio.nix
    ../modules/syncthing.nix
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
    ../modules/backup.nix
    ../modules/proton-workspace.nix
    ../modules/git-server.nix
    ../modules/fleet-vpn.nix
    ../modules/family/vpn-hub.nix
    ../modules/minecraft-server.nix
    ../modules/minecraft-servers.nix      # extra worlds on demand, in rootless podman
    ../modules/minecraft-couch.nix
    ../modules/minecraft-client.nix
    ../modules/valheim-server.nix
  ];

  networking.hostName = "hydrogen";
  system.stateVersion = "25.11";

  fleet.bootGenerations = 20;
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

  # Private git remotes, bare repos owned by the `git` account. No new port: sshd already
  # answers on wgadm and wgfam, so the kids' laptops can reach the account too and only
  # key-only auth keeps them out -- the same trade already made for the Minecraft control
  # channel below.
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
      ++ map (peer: peer.minecraftControlPublicKey) (builtins.attrValues peers.family);
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

  # THE ACCESS BOUNDARY -- read before changing any port.
  #
  # Every service is reachable only over WireGuard; being on the home wifi grants nothing,
  # not even sshd. minecraft-server runs online-mode=false and verifies no identity, so
  # whatever reaches 25565 may claim to be any child.
  #   wgadm (10.42.0.0/24, :51822)  sulfur -- full administrative access
  #   wgfam (10.41.0.0/24, :51821)  family devices -- web + Minecraft only
  # Only those two listen ports face the internet. Re-verify from off-tunnel after any
  # router change.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ ];   # every service port is interface-scoped below
  networking.firewall.allowedUDPPorts = [ 51821 51822 ];

  # openFirewall defaults true and adds 22 to the GLOBAL list, which no interface-scoped
  # rule can subtract from. 22 appears only in the wgadm list below.
  services.openssh.openFirewall = false;

  # sshd on the LAN, key-only, as the backup path. br0 used to carry nothing, which meant a
  # wgadm failure left no remote way in at all -- that cost a trip to the console on
  # 2026-08-19. The router does not forward 22, so this widens reach to the house, not the
  # internet. Every other service stays wgadm-scoped. see CHANGELOG 2026-08-19
  networking.firewall.interfaces."br0".allowedTCPPorts = [ 22 ];

  # br0 carries nothing, so a wgadm failure leaves no remote way in and recovery is the
  # physical console. That is survivable only because this is a laptop with a working
  # panel, GDM autologins sheath, and sheath has NOPASSWD sudo. Do not remove any of the
  # three without restoring a network path first.
  networking.firewall.interfaces."wgadm".allowedTCPPorts = [
    22
    80 443
    25565                           # Minecraft
    21115 21116 21117 21118 21119   # RustDesk
    22000                           # Syncthing
  ];
  networking.firewall.interfaces."wgadm".allowedUDPPorts = [
    2456 2457 2458   # Valheim
    21116           # RustDesk
    22000 21027     # Syncthing sync + discovery
  ];

  # Note what is absent: RustDesk, Syncthing.
  #
  # 22 is here so the kids' launchers can reach the on-demand server control channel, which
  # is SSH behind a forced command (modules/minecraft-servers.nix). Consequence, per the
  # guest note in modules/family/peers.nix: a guest key on wgfam can now reach sshd too.
  # Key-only auth is what stops them, not reachability. If guests become common, the
  # remedy that file suggests is a third hub carrying only the control port.
  networking.firewall.interfaces."wgfam".allowedTCPPorts = [ 22 80 443 25565 ];
  networking.firewall.interfaces."wgfam".allowedUDPPorts = [ 2456 2457 2458 ];

  # The on-demand worlds. A range rather than per-server entries: firewall ports are
  # declarative and per-interface, so a container the launcher creates at runtime on a
  # fresh port would otherwise be unreachable until the next rebuild. 25565 stays the
  # shared world.
  networking.firewall.interfaces."wgfam".allowedTCPPortRanges = [ { from = 25566; to = 25575; } ];
  networking.firewall.interfaces."wgadm".allowedTCPPortRanges = [ { from = 25566; to = 25575; } ];

  services.openssh = {
    enable = true;
    # Key-only, because 22 now faces the LAN as well as wgadm. A password prompt on the
    # house network is what the wgadm boundary existed to prevent, and sheath's hash is
    # shared with laptops the kids hold. see CHANGELOG 2026-08-19
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "no";
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
  # Direct-IP is the wgadm address 10.42.0.1, not the LAN one.
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

  # GUI on localhost; reach it with ssh -L 8384:localhost:8384. The sync ports are in the
  # wgadm list above, so sulfur syncs over the tunnel and nothing else reaches the daemon.
  services.syncthing.openDefaultPorts = false;
}
