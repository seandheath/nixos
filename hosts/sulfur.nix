# sulfur: the ASUS Zephyrus laptop. sheath's workstation.
{ lib, pkgs, config, ... }:

let
  devices = import ../modules/family/devices.nix;
in
{
  imports = [
    ../hardware/sulfur.nix
    ../modules/steam.nix
    ../modules/cemu.nix
    ../modules/workstation.nix
    ../modules/virtualisation.nix
    ../modules/impermanence.nix
    ../modules/minecraft-client.nix       # the offline client (game + mods pinned), shared with hydrogen
    ../modules/minecraft-launcher.nix     # pick a player and a server; spins servers up on demand
  ];

  # Resolved below to hydrogen's direct tail address.
  services.minecraftClient = {
    enable = true;
    playerName = "LuckyObserver";
    server = "mc.luckyobserver.com:25565";
  };

  # The plain client icon still quick-plays into the family world; this one asks first.
  services.minecraftLauncher.enable = true;
  services.minecraftLauncher.controlKeyFile = config.sops.secrets.minecraft-control-sulfur.path;
  sops.secrets.minecraft-control-sulfur = {
    owner = config.fleet.adminUser;
    mode = "0400";
  };

  fleet.bootGenerations = 20;
  # Keep the freeze investigation stable: GitHub rebuilds would replace these local fixes.
  # Resume once the validated fixes are published and the diagnostic trial is complete.
  systemd.timers.nixos-upgrade.enable = lib.mkForce false;
  fleet.tailscaleClient = {
    enable = true;
    tags = [ "tag:admin" ];
    acceptRoutes = false;
    operatorUser = config.fleet.adminUser;
    authKeyFile = config.sops.secrets.tailscale-auth-sulfur.path;
  };
  sops.secrets.tailscale-auth-sulfur = { };

  # sulfur wipes its root subvolume at boot, so the node key must live on /persist.
  environment.persistence."/persist".directories = [
    "/var/lib/tailscale"
    "/var/lib/systemd/pstore"  # Keep archived kernel crash records across boots.
  ];
  # Not sops: the age key lives under /home, which is exactly what has not mounted when
  # root recovery is needed.
  fleet.accounts.rootPassword = "persist";

  # Kernel deliberately unpinned: a pin would hold this laptop back long after nvidia-open
  # could handle newer, and a driver that refuses to build is a loud failure, not a silent
  # one. If that starts happening, pin the DRIVER.

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
  # PPD owns platform profiles and CPU EPP. Preserve the other existing ASUS settings.
  services.asusd.asusdConfig.text = ''
    (
      charge_control_end_threshold: 100,
      base_charge_control_end_threshold: 0,
      disable_nvidia_powerd_on_battery: true,
      ac_command: "",
      bat_command: "",
      platform_profile_linked_epp: false,
      platform_profile_on_battery: Quiet,
      change_platform_profile_on_battery: false,
      platform_profile_on_ac: Performance,
      change_platform_profile_on_ac: false,
      profile_quiet_epp: Power,
      profile_balanced_epp: BalancePower,
      profile_custom_epp: Performance,
      profile_performance_epp: Performance,
      ac_profile_tunings: {},
      dc_profile_tunings: {},
      armoury_settings: {},
    )
  '';
  systemd.services.asusd.restartTriggers = [ config.environment.etc."asusd/asusd.ron".source ];

  # asus-shutdown traps SIGTERM and defers exit; upstream ships SendSIGKILL=no with
  # TimeoutStopSec=45, so systemd cannot reap it and every rebuild that moves asusctl's
  # store path fails. restartIfChanged does not help -- the unit is PartOf=asusd.service.
  # See CHANGELOG 2026-08-13.
  systemd.services.asus-shutdown.serviceConfig = {
    SendSIGKILL = lib.mkForce true;
    TimeoutStopSec = lib.mkForce 10;
  };

  services.supergfxd.enable = true;

  services.power-profiles-daemon.enable = true;
  services.tuned.enable = lib.mkForce false;  # The GU605CW profile enables it by default.

  hardware = {
    enableRedistributableFirmware = true;
    nvidia = {
      open = true;  # recommended for RTX 50 series
      nvidiaSettings = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      powerManagement.finegrained = false;
      moduleParams.nvidia = {
        # Keep the existing runtime-D3 workaround while diagnosing freezes.
        # finegrained = false alone leaves runtime power management to the driver.
        NVreg_DynamicPowerManagement = "0x00";
        # Keep occupied VRAM in self-refresh during s2idle instead of copying it out.
        NVreg_EnableS0ixPowerManagement = 1;
        NVreg_S0ixPowerManagementVideoMemoryThreshold = 0;
      };
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

  # SysRq: diagnostic dumps (8) + sync (16), used by the keyd shortcut below.
  boot.kernel.sysctl."kernel.sysrq" = 24;
  # Bound ordinary journal buffering before a hard lockup or forced power-off.
  services.journald.settings.Journal.SyncIntervalSec = "30s";

  # Alt+PrintScreen or Alt+M4 dumps blocked tasks, CPU stacks, and memory, then syncs.
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings = let
        diagnostics = "macro2(0, 0, macro(leftalt+sysrq+w 200ms leftalt+sysrq+l 200ms leftalt+sysrq+m 200ms leftalt+sysrq+s))";
      in {
        main = {
          "leftshift+leftmeta" = "layer(control)";
          "prog1" = "sysrq";
        };
        alt = {
          sysrq = diagnostics;
          print = diagnostics;
          prog1 = diagnostics;
        };
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
  systemd.sleep.settings.Sleep.MemorySleepMode = "s2idle";
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
      User = config.fleet.adminUser;
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

  # Every hydrogen service uses its native tail address, at home and away.
  networking.hosts.${devices.hydrogen.tailAddress} = devices.serviceNames;

  system.stateVersion = "25.11";
}
