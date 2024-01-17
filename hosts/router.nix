# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports = [
    # Include the results of the hardware scan.
    #../modules/reverse-proxy.nix
    ../modules/core.nix
    ../modules/sops.nix
    ../users/user.nix
    ../users/veloren.nix
    ../modules/ddclient.nix
  ];

  boot.kernel.sysctl = {
    # Enable automatic reboot after kernel panic after 60s
    "kernel.panic" = 60;

    # Ignore ICMP broadcasts / DoS protection
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

    # Protect from SYN flood
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_max_syn_backlog" = 2048;
    "net.ipv4.tcp_synack_retries" = 3;

    # Enable forwarding
    "net.ipv4.conf.all.forwarding" = true;
    "net.ipv6.conf.all.forwarding" = true;

    # source: https://github.com/mdlayher/homelab/blob/master/nixos/routnerr-2/configuration.nix#L52
    # By default, not automatically configure any IPv6 addresses.
    "net.ipv6.conf.all.accept_ra" = 0;
    "net.ipv6.conf.all.autoconf" = 0;
    "net.ipv6.conf.all.use_tempaddr" = 0;

    # On WAN, allow IPv6 autoconfiguration and tempory address use.
    "net.ipv6.conf.enp3s0f1.accept_ra" = 2;
    "net.ipv6.conf.enp3s0f1.autoconf" = 1;

    # Update kernel buffer to 64M
    "net.core.wmem_max" = 67108864;
    "net.core.rmem_max" = 67108864;

    # Set TCP buffer limit to 32M
    "net.ipv4.tcp_wmem" = "10240 87380 33554432";
    "net.ipv4.tcp_rmem" = "10240 87380 33554432";

    # Enable window scaling
    "net.ipv4.tcp_window_scaling" = 1;
    "net.ipv6.tcp_window_scaling" = 1;

    # Enable timestamps
    "net.ipv4.tcp_timestamps" = 1;
    "net.ipv6.tcp_timestamps" = 1;

    # Enable select acknowledgements
    "net.ipv4.tcp_sack" = 1;

    # Set input backlog size
    "net.core.netdev_max_backlog" = 5000;

    # Set congestion control to htcp
    "net.ipv4.tcp_congestion_control" = "htcp";

    # Enable fair queueing
    "net.core.default_qdisc" = "fq";

    # Enable MTU probing for jumbo frames
    "net.ipv4.tcp_mtu_probing" = 1;
  };

  networking.hostName = "router";
  networking.wireless.enable = false;

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = false;
  networking.interfaces.enp3s0f0.useDHCP = false;
  networking.interfaces.enp4s0f0.useDHCP = false;
  networking.interfaces.enp4s0f1.useDHCP = false;
  networking.interfaces.eno1.useDHCP = false;

  # WAN Connection
  networking.interfaces.enp3s0f1 = {
    useDHCP = true;
    #mtu = 9000;
  };

  # LAN Connection
  networking.interfaces.enp3s0f0 = {
    mtu = 9000; # jumbo frames
    ipv4.addresses = [{
      address = "10.0.0.1";
      prefixLength = 24;
    }];
  };

  networking.firewall.enable = true;
  networking.firewall.trustedInterfaces = [
    "enp3s0f0"
  ];
  networking.firewall.allowedUDPPorts = [
    #53
  ];
  networking.firewall.allowedTCPPorts = [
    22
    #53
    #80
    #443
  ];
  networking.nat.enable = true;
  networking.nat.internalIPs = [
    "10.0.0.0/24"
  ];
  networking.nat.externalInterface = "enp3s0f1";
  networking.nat.forwardPorts = [
    {
      # SSH to Hydrogen
      destination = "10.0.0.2:22";
      proto = "tcp";
      sourcePort = 2345;
    }
    #{
      #sourcePort = 14004;
      #proto = "tcp";
      #destination = "10.0.0.10:14004";
    #}
  ];
  networking.nameservers = [ "10.0.0.1" ];
  networking.dhcpcd.persistent = true;

  services.dnsmasq = {
    enable = true;
    settings = {
      cache-size=1000;
      server = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      interface = "enp3s0f0";
      domain-needed = true;
      dhcp-range = ["10.0.0.100,10.0.0.200"];
    };
  };

  services.openssh = {
    enable = true;
    extraConfig = ''
      AuthorizedKeysFile .ssh/authorized_keys
      UsePAM yes
      UsePrivilegeSeparation sandbox
      PermitRootLogin no
      PasswordAuthentication no
      Match User veloren
        PasswordAuthentication yes
        AllowAgentForwarding no
        AllowTcpForwarding yes
        PermitOpen 10.0.0.10:14004
        ForceCommand /run/current-system/sw/bin/echo "Veloren Forwarding Enabled"
    '';
  };

  users.groups.ddclient = { };
  users.users.ddclient = {
    isSystemUser = true;
    group = "ddclient";
  };

  sops.secrets.ddclient-config.owner = config.users.users.ddclient.name;
  sops.secrets.ddclient-config.group = config.users.groups.ddclient.name;
  sops.secrets.ddclient-config.mode = "0400";

  services.ddclient = {
    enable = true;
    configFile = config.sops.secrets.ddclient-config.path;
  };

  systemd.services.ddclient.serviceConfig.User = pkgs.lib.mkForce config.users.users.ddclient.name;
  systemd.services.ddclient.serviceConfig.Group = pkgs.lib.mkForce config.users.groups.ddclient.name;

  # Disable sound.
  sound.enable = false;
  hardware.pulseaudio.enable = false;

  # Disable suspend
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" =
    {
      device = "/dev/disk/by-uuid/acd46d2e-bd44-4bda-8344-b9ae303979d3";
      fsType = "xfs";
    };

  fileSystems."/boot" =
    {
      device = "/dev/disk/by-uuid/FAA6-A714";
      fsType = "vfat";
    };

  swapDevices =
    [{ device = "/dev/disk/by-uuid/d88ed4ca-5af7-4b75-9b1e-49dbf1bba5cc"; }];
  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?

}
