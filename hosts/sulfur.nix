# sulfur: the ASUS Zephyrus laptop. sheath's workstation.
{ lib, pkgs, config, ... }:

let
  peers = import ../modules/family/peers.nix;
  adm = peers.hubs.adm;
  rtr = peers.routerMgmt;
in
{
  imports = [
    ../hardware/sulfur.nix
    ../modules/steam.nix
    ../modules/cemu.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
    ../modules/impermanence.nix
    ../modules/fleet-vpn.nix
    ../modules/minecraft-client.nix       # the offline client (game + mods pinned), shared with hydrogen
    ../modules/minecraft-launcher.nix     # pick a player and a server; spins servers up on demand
  ];

  # Reached by name over wgadm; networking.hosts below resolves it. See docs/minecraft.md.
  services.minecraftClient = {
    enable = true;
    playerName = "LuckyObserver";
    server = "mc.luckyobserver.com:25565";
  };

  # The plain client icon still quick-plays into the family world; this one asks first.
  services.minecraftLauncher.enable = true;
  services.minecraftLauncher.controlKeyFile = config.sops.secrets.minecraft-control-sulfur.path;
  sops.secrets.minecraft-control-sulfur = {
    owner = "sheath";
    mode = "0400";
  };

  fleet.bootGenerations = 20;
  # Not sops: the age key lives under /home, which is exactly what has not mounted when
  # root recovery is needed.
  fleet.accounts.rootPassword = "persist";

  # Kernel deliberately unpinned: a pin would hold this laptop back long after nvidia-open
  # could handle newer, and a driver that refuses to build is a loud failure, not a silent
  # one. If that starts happening, pin the DRIVER.
  #
  # 0x00 is the only value that keeps the dGPU out of D3cold; finegrained = false merely
  # omits the modparam and lets the driver choose, which since 610 means RTD3 on. Verify
  # after a driver bump: grep DynamicPowerManagement /proc/driver/nvidia/params -> 0.
  # One block only -- a second assignment here is a duplicate-key error, not a merge.
  boot.extraModprobeConfig = ''
    options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_DynamicPowerManagement=0x00
  '';

  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
  };

  networking.hostName = "sulfur";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;
  # The Intel driver hit `Tx queue alloc failed` while roaming, leaving LAN traffic at
  # triple-digit latency even after NetworkManager re-associated. Disable its independent
  # power-save path too; NetworkManager's setting above does not set this module option.
  boot.kernelParams = [ "iwlwifi.power_save=0" ];

  environment.systemPackages = with pkgs; [
    asusctl
    supergfxctl
    zlib
    pciutils
    usbutils
    lshw
    file
    btrfs-progs
    jackify
  ];

  services.asusd.enable = true;

  # asus-shutdown traps SIGTERM and defers exit; upstream ships SendSIGKILL=no with
  # TimeoutStopSec=45, so systemd cannot reap it and every rebuild that moves asusctl's
  # store path fails. restartIfChanged does not help -- the unit is PartOf=asusd.service.
  # See CHANGELOG 2026-08-13.
  systemd.services.asus-shutdown.serviceConfig = {
    SendSIGKILL = lib.mkForce true;
    TimeoutStopSec = lib.mkForce 10;
  };

  services.supergfxd.enable = true;
  systemd.services.supergfxd.path = [ pkgs.pciutils ];

  services.power-profiles-daemon.enable = true;

  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      open = true;  # recommended for RTX 50 series
      nvidiaSettings = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      # Necessary but NOT sufficient -- see the modparam above. RTD3 assumes an
      # offload-only dGPU; the dock's display hangs off a card0/nvidia-drm connector, so a
      # link drop lets the GPU reach D3cold while Mutter still holds an active KMS output
      # on it and gnome-shell deadlocks. Re-enable only if every external display is
      # routed to the Intel GPU.
      powerManagement.finegrained = false;
      # Deliberately unpinned, unlike hydrogen: the RTD3 defence is the modparam, which
      # keeps working as the driver moves. Freezing trades a loud break for a silent one.
      package = config.boot.kernelPackages.nvidiaPackages.latest;
      prime = {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        # lspci
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        nvidia-vaapi-driver
      ];
    };
  };

  # Copilot key (shift+meta+f23) becomes a Ctrl layer; M4 (prog1) becomes SysRq.
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings.main = {
        "leftshift+leftmeta" = "layer(control)";
        "prog1" = "sysrq";
      };
    };
  };

  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      disableWhileTyping = true;
    };
  };

  # Lower thresholds = more aggressive palm rejection. keyd's virtual keyboard has to be
  # marked internal or disable-while-typing never fires.
  environment.etc."libinput/local-overrides.quirks".text = ''
    [ASUS Touchpad]
    MatchUdevType=touchpad
    MatchName=*ASUF1209*
    AttrPalmSizeThreshold=50
    AttrPalmPressureThreshold=70
    AttrThumbSizeThreshold=40
    AttrThumbPressureThreshold=60

    [Keyd Virtual Keyboard]
    MatchUdevType=keyboard
    MatchName=keyd virtual keyboard
    AttrKeyboardIntegration=internal
  '';

  services.fwupd.enable = true;

  # Prevent suspend when on AC power (docked)
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "suspend";
    HandleSuspendKey = "suspend";
    IdleAction = "ignore";
  };

  # Reconfigure monitors when the dock connects. mkAfter: hardware/sulfur.nix also sets
  # this option.
  services.udev.extraRules = lib.mkAfter ''
    ACTION=="change", SUBSYSTEM=="drm", RUN+="${pkgs.systemd}/bin/systemctl start --no-block dock-monitors-hotplug.service"
  '';

  systemd.services.dock-monitors-hotplug = {
    description = "Reapply monitor configuration on display hotplug";
    after = [ "graphical.target" ];
    serviceConfig = {
      Type = "oneshot";
      # No session bus, nothing to reconfigure. The udev rule fires on DRM events with no
      # graphical session behind them, and a failed unit here is counted by
      # switch-to-configuration -- it turns a clean nightly into a failure report. A failing
      # ExecCondition marks the unit skipped, so a real DBus error still surfaces.
      ExecCondition = "${pkgs.coreutils}/bin/test -S /run/user/1000/bus";
      # Let Mutter enumerate the new displays first.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${pkgs.dock-monitors.pythonWithDbus}/bin/python3 ${pkgs.dock-monitors.script}";
      User = "sheath";
      Environment = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus";
    };
    # Debounce: DRM fires several events per dock connect.
    startLimitIntervalSec = 30;
    startLimitBurst = 1;
  };

  programs.gamemode = {
    enable = true;
    settings = {
      general = {
        renice = 10;
      };
      gpu = {
        apply_gpu_optimisations = "accept-responsibility";
        gpu_device = 0;
      };
      custom = {
        start = "${pkgs.libnotify}/bin/notify-send 'GameMode started'";
        end = "${pkgs.libnotify}/bin/notify-send 'GameMode ended'";
      };
    };
  };

  # wg0: break-glass path to the whole home LAN, for when wgadm or hydrogen's sops decrypt
  # is what broke. Recovery access that depends on the thing being recovered is not
  # recovery access. Manual: `nmcli connection up wg0`.
  sops.secrets.wg-priv-sulfur = { };

  networking.networkmanager.ensureProfiles.profiles.wg0 = {
    connection = {
      id = "wg0";
      uuid = "3e85818d-68f1-4d86-ba79-94df12d8412d"; # pinned, or NM invents one per boot
      type = "wireguard";
      interface-name = "wg0";
      autoconnect = false;
    };

    wireguard = {
      private-key-flags = 1; # agent-owned
      mtu = 1420;
      peer-routes = true;
    };

    "wireguard-peer.ILwElzleBCCQ8vrGGiV2gUY0B33IHB456MQtgT2ZUTE=" = {
      allowed-ips = "10.0.0.0/24;10.40.0.0/24;";
      endpoint = "${peers.routerEndpointHost}:51820";
      persistent-keepalive = 25;
    };

    ipv4 = {
      method = "manual";
      address1 = "10.40.0.3/24";
      # Below the Wi-Fi route (600), so being on the LAN beats tunnelling to reach it.
      route-metric = 1000;
      never-default = true;
    };
    ipv6.method = "disabled";
  };



  # wgadm is always-on infrastructure, owned by systemd just like Hydrogen's two hubs.
  # Keeping it out of NetworkManager avoids an interactive secret-agent dependency and
  # prevents desktop connection reloads from replacing the live interface's key or routes.
  sops.secrets.${peers.admin.sulfur.secret} = { };
  networking.wireguard.interfaces.${adm.interface} = {
    ips = [ "${peers.admin.sulfur.address}/32" ];
    privateKeyFile = config.sops.secrets.${peers.admin.sulfur.secret}.path;
    mtu = 1420;
    peers = [
      {
        inherit (adm) publicKey;
        allowedIPs = [ "${adm.address}/32" peers.hubs.fam.subnet ];
        endpoint = "${peers.hydrogenEndpointHost}:${toString adm.port}";
        persistentKeepalive = 25;
      }
      {
        inherit (rtr) publicKey;
        allowedIPs = [ "${rtr.address}/32" ];
        endpoint = "${peers.routerEndpointHost}:${toString rtr.port}";
        persistentKeepalive = 25;
      }
    ];
  };

  # The manual break-glass profile remains a NetworkManager toggle. Its key is handed to
  # NM over D-Bus rather than written into a connection file.
  networking.networkmanager.ensureProfiles.secrets.entries = [
    {
      matchId = "wg0";
      matchType = "wireguard";
      matchSetting = "wireguard";
      key = "private-key";
      file = config.sops.secrets.wg-priv-sulfur.path;
      trim = true;
    }
  ];

  # hydrogen's vhosts on the admin tunnel, under their public names so the wildcard cert
  # still matches.
  networking.hosts.${adm.address} = peers.serviceNames;

  # Stable SSH destinations: the laptops' LAN leases change, but their family-tunnel
  # addresses do not. Hydrogen forwards only sulfur's TCP/22 traffic to these peers.
  programs.ssh.extraConfig = ''
    Host hydrogen
      HostName ${adm.address}
      User sheath
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes

    Host router nixrouter
      HostName ${rtr.address}
      User admin
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
      IPQoS none

    Host router-lan
      HostName ${rtr.lanAddress}
      User admin
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
      IPQoS none

    Host hydrogen-git
      HostName ${adm.address}
      User git
  '' + lib.concatStrings (lib.mapAttrsToList (name: peer: ''
    Host ${name}
      HostName ${peer.address}
      User sheath
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
  '') peers.family);


  system.stateVersion = "25.11";
}
