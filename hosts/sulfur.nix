{ lib, pkgs, config, ... }:

let
  dock-monitors = import ../packages/dock-monitors.nix { inherit pkgs; };
  peers = import ../modules/family/peers.nix;
  adm = peers.hubs.adm;
in
{
  imports = [
    ../hardware/sulfur.nix
    ../modules/steam.nix
    ../modules/mo2.nix
    ../modules/cemu.nix
    ../modules/farcry2.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
    ../modules/impermanence.nix
    ../modules/wivrn.nix
    ../modules/fleet-vpn.nix
    ../modules/minecraft-client.nix       # the offline client (game + mods pinned), shared with hydrogen
    ../modules/family/wg-endpoint.nix     # keeps wgadm pointed at the LAN or the WAN
  ];

  # Minecraft client for hydrogen's server (modules/minecraft-server.nix). Reached by
  # name over wgadm now, not at 10.0.0.10 -- 25565 is no longer open on the LAN
  # (hosts/hydrogen.nix). networking.hosts below resolves the name to 10.42.0.1. The
  # whole game -- jar, libraries, assets, JVM, mods -- is a pinned Nix payload
  # (packages/minecraft-client), so the desktop entry starts a playable,
  # correctly-modded client on a machine that has never run it. See docs/minecraft.md.
  services.minecraftClient = {
    enable = true;
    playerName = "LuckyObserver";
    server = "mc.luckyobserver.com:25565";
  };

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;

  # Pin to 6.18 until nvidia-open supports kernel 6.19
  boot.kernelPackages = pkgs.linuxPackages_6_18;

  # NVIDIA settings for RTX 50 series
  boot.extraModprobeConfig = ''
    options nvidia NVreg_PreserveVideoMemoryAllocations=1
  '';

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  services.xserver.xkb.layout = "us";

  # Display
  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
  };

  # Networking
  networking.hostName = "sulfur";
  networking.networkmanager.enable = true;
  networking.networkmanager.wifi.powersave = false;

  # Programs
  environment.systemPackages = with pkgs; [
    asusctl
    supergfxctl
    zlib
    pciutils
    usbutils
    lshw
    file
    btrfs-progs
    (callPackage ../packages/jackify.nix {})

    # Veloren client (veloren-voxygen), for hydrogen's server in
    # modules/veloren-server.nix. Veloren refuses cross-version connections, so this must
    # stay the same flake pin as hydrogen — that lock-step is why the client comes from
    # nixpkgs and not from Airshipper, which self-updates to upstream weekly nightlies.
    veloren
    # Minecraft is services.minecraftClient above, not a package here.
  ];

  # ASUS ROG services
  services.asusd = {
    enable = true;
    enableUserService = true;
  };

  services.supergfxd.enable = true;
  systemd.services.supergfxd.path = [ pkgs.pciutils ];

  # Power management
  services.power-profiles-daemon.enable = true;

  # Hardware configuration
  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      open = true;  # Use open source kernel modules (recommended for RTX 50 series)
      nvidiaSettings = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = true;  # Fine-grained power management for laptops
      package = config.boot.kernelPackages.nvidiaPackages.latest;
      prime = {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        # Bus IDs from lspci output
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

  # Remap Copilot key (sends shift+meta+f23 simultaneously) to Ctrl layer
  # The combo activates a control layer instead of outputting a key directly
  # Remap M4 button (KEY_PROG1) to Print Screen for screenshots
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

  # Touchpad configuration with palm rejection
  services.libinput = {
    enable = true;
    touchpad = {
      tapping = true;
      naturalScrolling = true;
      disableWhileTyping = true;
    };
  };

  # Quirks for ASUS touchpad palm detection and keyd integration
  # Lower thresholds = more aggressive palm rejection
  # keyd virtual keyboard must be marked as internal for DWT to work
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

  # Services
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

  # Reconfigure monitors on display hotplug (e.g. docking station reconnect)
  # Watches for DRM connector change events from the kernel
  services.udev.extraRules = lib.mkAfter ''
    ACTION=="change", SUBSYSTEM=="drm", RUN+="${pkgs.systemd}/bin/systemctl start --no-block dock-monitors-hotplug.service"
  '';

  # System service that runs dock-monitors as the logged-in user on hotplug
  systemd.services.dock-monitors-hotplug = {
    description = "Reapply monitor configuration on display hotplug";
    after = [ "graphical.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Wait for Mutter to detect and enumerate new displays
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
      ExecStart = "${dock-monitors.pythonWithDbus}/bin/python3 ${dock-monitors.script}";
      User = "sheath";
      Environment = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus";
    };
    # Debounce: DRM fires multiple events per dock connect, only run once per 30s
    startLimitIntervalSec = 30;
    startLimitBurst = 1;
  };

  # GameMode configuration
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

  # WireGuard configuration for home LAN access
  sops.secrets.wg-priv-sulfur = { };

  networking.wg-quick.interfaces.wg0 = {
    address = [ "10.40.0.3/24" ];
    privateKeyFile = config.sops.secrets.wg-priv-sulfur.path;
    table = "off"; # Prevent wg-quick from auto-adding routes to the main table
    
    peers = [
      {
        publicKey = "ILwElzleBCCQ8vrGGiV2gUY0B33IHB456MQtgT2ZUTE=";
        allowedIPs = [ "10.0.0.0/24" "10.40.0.0/24" ];
        endpoint = "vpn.luckyobserver.com:51820";
        persistentKeepalive = 25;
      }
    ];

    postUp = ''
      # Add route to home LAN with high metric (1000) so local Wi-Fi route takes precedence when at home
      ip route add 10.0.0.0/24 dev wg0 metric 1000
    '';

    postDown = ''
      ip route del 10.0.0.0/24 dev wg0 metric 1000 || true
    '';
  };

  # --------------------------------------------------------------------------
  # sheath's login password, from sops rather than /persist/secrets/sheath-password.
  #
  # modules/impermanence.nix already sets users.mutableUsers = false and points this at a
  # plaintext hash that install.sh writes once, by hand, per machine -- so the password on
  # this laptop, hydrogen and the four kids' laptops could drift apart with nothing to
  # notice. One sops entry is now the source for all six.
  #
  # It lives in secrets/family.yaml, which needs saying: that file is encrypted to the
  # main key AND the family key (see .sops.yaml), so this host reads it with the main key
  # it already has. sopsFile is explicit because this host's defaultSopsFile is
  # secrets/secrets.yaml.
  #
  # root is deliberately left on /persist/secrets/root-password. It is the recovery path
  # for a machine whose /home -- and therefore whose age key -- did not mount, and that is
  # exactly when a sops-backed password would be unavailable.
  #
  # REVERT: drop these two lines. /persist/secrets/sheath-password is still there and
  # modules/impermanence.nix picks it back up.
  sops.secrets."sheath-password-hash" = {
    sopsFile = ../secrets/family.yaml;
    neededForUsers = true;
  };
  users.users.sheath.hashedPasswordFile =
    lib.mkForce config.sops.secrets."sheath-password-hash".path;

  # --------------------------------------------------------------------------
  # wgadm: the administrative tunnel to hydrogen (modules/family/vpn-hub.nix).
  #
  # This is now the ONLY way into hydrogen's services. As of 2026-08-06 that host
  # scopes every service port to a WireGuard interface and keeps nothing but sshd on
  # br0, so SSH, RustDesk, Syncthing, Immich, Nextcloud, Paperless and Minecraft all
  # arrive here. wg0 above stays as it is -- it reaches the LAN, which is the
  # break-glass path if this tunnel or hydrogen's sops decrypt ever breaks.
  #
  # 10.41.0.0/24 is in allowedIPs because sulfur administers the kids' laptops over
  # SSH; hydrogen forwards exactly port 22 in that direction and drops the rest.
  sops.secrets.${peers.admin.sulfur.secret} = { };

  networking.wg-quick.interfaces.${adm.interface} = {
    # /32 with explicit host/route entries, so nothing here can shadow the local
    # network the way a /24 would -- no `table = "off"` dance needed, unlike wg0.
    address = [ "${peers.admin.sulfur.address}/32" ];
    privateKeyFile = config.sops.secrets.${peers.admin.sulfur.secret}.path;

    peers = [{
      publicKey = adm.publicKey;
      allowedIPs = [ "${adm.address}/32" peers.hubs.fam.subnet ];
      # Rewritten at runtime to hydrogen's LAN address when sulfur is at home; see
      # modules/family/wg-endpoint.nix. This is the fallback.
      endpoint = "${peers.endpointHost}:${toString adm.port}";
      persistentKeepalive = 25;
    }];
  };

  family.wgEndpoint.${adm.interface} = {
    inherit (adm) publicKey port;
  };

  # hydrogen's vhosts, resolved to the admin tunnel. Same names as the public ones, so
  # the wildcard cert in modules/reverse-proxy.nix still matches.
  networking.hosts.${adm.address} = peers.serviceNames;

  # Required to avoid dropping asymmetric routing replies from WireGuard interface
  networking.firewall.checkReversePath = "loose";

  # Configure Mullvad settings automatically on boot/activation
  systemd.services.mullvad-configure = {
    description = "Configure Mullvad settings (LAN sharing and custom DNS)";
    after = [ "mullvad-daemon.service" ];
    requires = [ "mullvad-daemon.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "mullvad-configure" ''
        # Wait for mullvad daemon to be fully ready
        until ${config.services.mullvad-vpn.package}/bin/mullvad status >/dev/null 2>&1; do
          sleep 1
        done
        ${config.services.mullvad-vpn.package}/bin/mullvad lan set allow
        ${config.services.mullvad-vpn.package}/bin/mullvad dns set custom 10.0.0.1 1.1.1.1
      '';
    };
  };

  system.stateVersion = "25.11";
}
