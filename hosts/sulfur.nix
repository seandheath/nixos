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

  # Reached through the home subnet route; networking.hosts below resolves it.
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
  fleet.tailscaleClient = {
    enable = true;
    tags = [ "tag:admin" ];
    authKeyFile = config.sops.secrets.tailscale-auth-sulfur.path;
  };
  sops.secrets.tailscale-auth-sulfur = { };

  # sulfur wipes its root subvolume at boot, so the node key must live on /persist.
  environment.persistence."/persist".directories = [ "/var/lib/tailscale" ];
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

  # Ordinary services use the advertised LAN route. Marketplace is reached on
  # hydrogen's direct tail address so Headscale can enforce its admin-only ACL.
  networking.hosts."10.0.0.10" =
    lib.remove "marketplace.luckyobserver.com" devices.serviceNames;
  networking.hosts."100.64.0.3" = [ "marketplace.luckyobserver.com" ];

  # Stable SSH destinations use Headscale MagicDNS. The LAN aliases remain for
  # local recovery when the control plane is unavailable.
  programs.ssh.extraConfig = ''
    Host hydrogen
      HostName hydrogen.tail.luckyobserver.com
      User sheath
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes

    Host hydrogen-lan
      HostName 10.0.0.10
      User sheath
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes

    Host router nixrouter
      HostName router.tail.luckyobserver.com
      User admin
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
      IPQoS none

    Host router-lan
      HostName 10.0.0.1
      User admin
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
      IPQoS none

    Host hydrogen-git
      HostName hydrogen.tail.luckyobserver.com
      User git
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
  '' + lib.concatStrings (lib.mapAttrsToList (name: peer: ''
    Host ${name}
      HostName ${name}.tail.luckyobserver.com
      User sheath
      IdentityFile /home/sheath/.ssh/personal
      IdentitiesOnly yes
  '') devices.family);


  system.stateVersion = "25.11";
}
