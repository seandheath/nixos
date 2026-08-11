{ lib, pkgs, config, ... }:

let
  dock-monitors = import ../packages/dock-monitors.nix { inherit pkgs; };
  peers = import ../modules/family/peers.nix;
  adm = peers.hubs.adm;
  rtr = peers.routerMgmt;
in
{
  imports = [
    ../hardware/sulfur.nix
    ../modules/steam.nix
    ../modules/mo2.nix
    ../modules/cemu.nix
    # TEMPORARILY OUT (2026-08-10). packages/farcry2-realismredux.nix pins the mod
    # through requireFile, and the 7z was garbage-collected: the built tree survived
    # in the store but the source did not, so the 26.05 stdenv change -- which gives
    # the mod derivation a new hash -- has nothing to build from. Re-download
    # FC2-RealismPlusRedux-326-v1.2.5.7z from nexusmods.com/farcry2/mods/326,
    #   nix-store --add-fixed sha256 FC2-RealismPlusRedux-326-v1.2.5.7z
    # and uncomment. Installed game files are unaffected; only fc2-apply-mods is gone.
    # ../modules/farcry2.nix
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
  # enableUserService was dropped in 26.05 -- asusd no longer needs a per-user
  # service, and defining the option is now a hard assertion failure.
  services.asusd.enable = true;

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
      # Fine-grained RTD3 (DynamicPowerManagement=2) must stay OFF here: the dock's
      # HP Z27x (CNK71609WJ) hangs off HDMI-2, which is a card0/nvidia-drm connector
      # (card1/i915 only exposes HDMI-A-1, DP-1..3, eDP-1). RTD3 assumes an
      # offload-only dGPU with no attached displays; with one attached, a dock link
      # drop lets the GPU fall into D3cold while Mutter still holds an active KMS
      # output on it, and the compositor deadlocks in an NVIDIA ioctl against a
      # powered-down GPU. That froze the session on 2026-08-11 14:08 (kernel stayed
      # alive and logging; only gnome-shell wedged). Re-enable only if every
      # external display is routed to the Intel GPU.
      powerManagement.finegrained = false;
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

  # ==========================================================================
  # The tunnels, as NetworkManager profiles rather than wg-quick interfaces.
  #
  # WHY NM OWNS THESE NOW. NM manages WireGuard devices whether or not we want it to
  # (see modules/wg-unmanaged.nix for what that cost). The choice is therefore not
  # "NM or not" but "NM as a spectator or NM as the owner", and a spectator is the
  # dangerous one: it offers a toggle in GNOME that flushes the address and routes out
  # from under a systemd unit that goes on reporting success. Handing NM the whole
  # configuration makes the same toggle correct -- deactivating tears the tunnel down,
  # activating rebuilds it from config NM actually holds -- and puts real status in the
  # panel, which during the 2026-08-09 incident was the only source that told the truth
  # while systemctl and `wg show` both reported health.
  #
  # DO NOT EDIT these connections in the GNOME UI. Toggling is safe and is the point;
  # editing is not. These profiles are rendered to /run/NetworkManager/system-connections
  # and NM responds to an edit by copying the connection to /etc and treating it as
  # ad-hoc -- so the next time NetworkManager-ensure-profiles runs you have two profiles
  # for one interface, competing. Change them here instead.
  #
  # Private keys are NOT in these profiles. wireguard.private-key-flags = 1 marks the key
  # agent-owned, and nm-file-secret-agent (ensureProfiles.secrets below) hands it to NM
  # from the existing sops path on demand. So the key stays exactly where it already was
  # and never lands in a connection file -- no new secret, and secrets.yaml is untouched.
  #
  # Peer sections must be ONE attribute name containing a literal dot. Nesting it as
  # wireguard-peer."${key}" is a type error, not a section: pkgs.formats.ini is two levels
  # deep and the peer key belongs in the section name, where base64's / + = pass through
  # untouched.
  # ==========================================================================

  # --------------------------------------------------------------------------
  # wg0 -- the break-glass path to the home LAN. MANUAL, never at boot.
  #
  # wgadm below is the everyday tunnel. wg0 exists to reach the whole home LAN
  # (10.0.0.0/24), and through it hydrogen's sshd on br0, when wgadm itself or hydrogen's
  # sops decrypt is what broke. Recovery access whose availability depends on the thing
  # being recovered is not recovery access, so it stays declared -- but autoconnect is
  # off, and it is switched on from the GNOME panel or with:
  #   nmcli connection up wg0 / nmcli connection down wg0
  #
  # The endpoint is a hostname again, and that is now safe. Under wg-quick it was not:
  # wg-quick resolves the endpoint during `wg setconf`, so a boot that beat the Wi-Fi
  # killed the unit outright and left it dead for the session (2026-08-08 and -09). NM
  # resolves asynchronously and retries the activation instead of destroying the
  # interface.
  sops.secrets.wg-priv-sulfur = { };

  networking.networkmanager.ensureProfiles.profiles.wg0 = {
    connection = {
      id = "wg0";
      uuid = "3e85818d-68f1-4d86-ba79-94df12d8412d"; # pinned: without it NM invents a new one per boot and duplicates the profile
      type = "wireguard";
      interface-name = "wg0";
      autoconnect = false; # break glass, by hand
    };

    wireguard = {
      private-key-flags = 1; # agent-owned; supplied by nm-file-secret-agent below
      mtu = 1420;
      peer-routes = true;
    };

    "wireguard-peer.ILwElzleBCCQ8vrGGiV2gUY0B33IHB456MQtgT2ZUTE=" = {
      allowed-ips = "10.0.0.0/24;10.40.0.0/24;";
      endpoint = "vpn.luckyobserver.com:51820";
      persistent-keepalive = 25;
    };

    ipv4 = {
      method = "manual";
      address1 = "10.40.0.3/24";
      # route-metric replaces the old `table = "off"` plus a postUp/postDown pair that
      # added and removed `10.0.0.0/24 dev wg0 metric 1000` by hand. Same outcome, one
      # line: the tunnel's route to the home LAN sits below the Wi-Fi route (metric 600),
      # so being on the LAN still beats going through the tunnel to reach it.
      route-metric = 1000;
      never-default = true;
    };
    ipv6.method = "disabled";
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
  # arrive here. wg0 above remains the break-glass path to the LAN if this tunnel or
  # hydrogen's sops decrypt ever breaks.
  #
  # 10.41.0.0/24 is in allowedIPs because sulfur administers the kids' laptops over
  # SSH; hydrogen forwards exactly port 22 in that direction and drops the rest.
  sops.secrets.${peers.admin.sulfur.secret} = { };

  networking.networkmanager.ensureProfiles.profiles.${adm.interface} = {
    connection = {
      id = adm.interface;
      uuid = "e34208d7-8dd2-4274-bbed-520d43fd7994";
      type = "wireguard";
      interface-name = adm.interface;
      autoconnect = true; # the everyday tunnel: up at boot, up always
    };

    wireguard = {
      private-key-flags = 1; # agent-owned; supplied by nm-file-secret-agent below
      mtu = 1420;
      peer-routes = true;
    };

    # TWO peers on one interface, and that is the whole point. hydrogen and the router
    # are peers of sulfur, not of each other -- WireGuard has no hubs, only pairs -- so
    # losing hydrogen costs nothing on the router and vice versa. The router's own
    # administration used to sit on brLan; it is on its tunnel now.
    #
    # The endpoint is a bootstrap value: modules/family/wg-endpoint.nix owns endpoint
    # selection and rewrites it with `wg set` once the interface is up. It stays the LAN
    # literal rather than the public name because being merely wrong when away costs one
    # wg-endpoint run to correct, and that run is triggered by the same NM connectivity
    # event that would have reset it.
    "wireguard-peer.${adm.publicKey}" = {
      allowed-ips = "${adm.address}/32;${peers.hubs.fam.subnet};";
      endpoint = "${peers.lanEndpoint}:${toString adm.port}";
      persistent-keepalive = 25;
    };

    # The router, addressed at its TUNNEL address (10.42.0.1) and never at 10.0.0.1.
    #
    # THIS COST AN OUTAGE, so it is worth being explicit, and it survives the move from
    # wg-quick unchanged: NM installs a route for every allowed-ips entry exactly as
    # wg-quick did (peer-routes = true above). Listing 10.0.0.1/32 here put a
    # more-specific route to this machine's own DEFAULT GATEWAY AND DNS SERVER inside the
    # tunnel: name resolution died, the default route could not resolve its next hop, and
    # all internet access stopped. It was circular too -- the endpoint below is 10.0.0.1,
    # which was then routed into the tunnel it was trying to build.
    #
    # Any address a client might also need off-tunnel must stay off this list. For the
    # LAN gateway that is not a preference, it is a hard rule.
    "wireguard-peer.${rtr.publicKey}" = {
      allowed-ips = "${rtr.address}/32;";
      endpoint = "${rtr.lanAddress}:${toString rtr.port}";
      persistent-keepalive = 25;
    };

    ipv4 = {
      # /32 with explicit host routes from allowed-ips, so nothing here can shadow the
      # local network the way a /24 would -- no route-metric games needed, unlike wg0.
      method = "manual";
      address1 = "${peers.admin.sulfur.address}/32";
      never-default = true;
    };
    ipv6.method = "disabled";
  };

  # The private keys, handed to NM over D-Bus by nm-file-secret-agent rather than written
  # into any connection file. `file` points at the sops path each tunnel already used as
  # its privateKeyFile, so nothing about secret storage changed: same secret, same path,
  # same permissions, and secrets.yaml is untouched. trim strips the trailing newline
  # sops leaves on the value.
  networking.networkmanager.ensureProfiles.secrets.entries = [
    {
      matchId = adm.interface;
      matchType = "wireguard";
      matchSetting = "wireguard";
      key = "private-key";
      file = config.sops.secrets.${peers.admin.sulfur.secret}.path;
      trim = true;
    }
    {
      matchId = "wg0";
      matchType = "wireguard";
      matchSetting = "wireguard";
      key = "private-key";
      file = config.sops.secrets.wg-priv-sulfur.path;
      trim = true;
    }
  ];

  # Per-PEER endpoint selection, not per-interface: these two live at different
  # addresses on the home LAN, and probing one for both would leave the loser
  # unreachable from the house.
  family.wgEndpoint = [
    {
      interface = adm.interface;
      inherit (adm) publicKey port;
      lanHost = peers.lanEndpoint;          # hydrogen, 10.0.0.10
      publicHost = peers.endpointHost;      # hub.luckyobserver.com
    }
    {
      interface = adm.interface;
      inherit (rtr) publicKey port;
      lanHost = rtr.lanAddress;             # the router, 10.0.0.1
      # vpn., not hub.: that name always resolves to the WAN address, which is exactly
      # right here. The router peer only has to work when away -- at home kids.lan is
      # plain nginx on brLan, no tunnel involved.
      publicHost = "vpn.luckyobserver.com";
    }
  ];

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

        # 1.1.1.1 ALONE, and the address that is NOT here is the point.
        #
        # This used to read `custom 10.0.0.1 1.1.1.1`. Mullvad rewrites /etc/resolv.conf
        # to exactly the listed servers, in order, whenever it connects -- and 10.0.0.1
        # is the home router, reachable only on the home LAN or through wg0, which is
        # now a manual tunnel. glibc has no notion of a nameserver being unreachable,
        # only of one being slow, so it would try 10.0.0.1 first and eat a 5s timeout on
        # every lookup before falling through to 1.1.1.1.
        #
        # HONESTY ABOUT PROVENANCE: this was found while chasing a DNS outage on
        # 2026-08-09 and initially blamed for it. It was not the cause -- the daemon log
        # shows Mullvad never connected on that boot or the one before, so this setting
        # was never applied. The real culprit was NetworkManager flushing wgadm (see
        # modules/family/wg-endpoint.nix). This remains a genuine latent bug, fixed on
        # its own merits, and the rule it encodes is worth keeping: a resolver whose
        # reachability depends on a tunnel must never be first in resolv.conf.
        #
        # What is lost is the router's ad/tracker filtering while connected; that was a
        # deliberate call, not an oversight. The five split-horizon names still resolve
        # from networking.hosts below -- nsswitch reads `files` before `dns` -- so local
        # services resolve identically at home, remote, and with Mullvad up.
        ${config.services.mullvad-vpn.package}/bin/mullvad dns set custom 1.1.1.1
      '';
    };
  };

  system.stateVersion = "25.11";
}
