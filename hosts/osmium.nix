# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ lib, pkgs, config, ... }:

{
  imports = [
    ../modules/hyprland.nix
    ../modules/virtualisation.nix
    ../modules/syncthing.nix
  ];

  # Boot
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "thunderbolt" "nvme" "uas" "sd_mod" "sdhci_pci" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "evdi" ];
  boot.extraModulePackages = [ config.boot.kernelPackages.evdi ];
  boot.initrd.luks.devices."luks-a6ea78d6-7a09-4994-b09c-48863e41e765".device = "/dev/disk/by-uuid/a6ea78d6-7a09-4994-b09c-48863e41e765";
  boot.initrd.luks.devices."luks-b1189935-07c6-416d-9201-b555aa272104".device = "/dev/disk/by-uuid/b1189935-07c6-416d-9201-b555aa272104";

  # Filesystem
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/2ba22a8f-7299-45c8-a4ca-6fd1a087c629";
      fsType = "ext4";
    };
  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/96EB-2493";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };
  swapDevices =
    [ { device = "/dev/disk/by-uuid/14158464-b3bd-4eb2-bcf0-2fbee84f782c"; }
    ];

  # Kernel
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Configuration
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };
  services.printing.enable = true;
  services.flatpak.enable = true;

  # Sound
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Display
  services.xserver = {
  	enable = true;
	videoDrivers = [ "nvidia" "displaylink" "modesetting" ];
  };
  # DisplayLink
  systemd.services.dlm.wantedBy = [ "multi-user.target" ];
  boot = {
  };

  # Hyprland is configured in modules/hyprland.nix

  # Networking
  networking.hostName = "osmium"; # Define your hostname.
  networking.networkmanager.enable = true;
  networking.useDHCP = lib.mkDefault true;

  ## Mullvad
  services.mullvad-vpn.enable = true;

  # Programs
  nixpkgs.config.allowUnfree = true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  environment.systemPackages = with pkgs; [
    (heroic.override { extraPkgs = pkgs: [ pkgs.gamescope ]; })
    system76-firmware
    system76-keyboard-configurator
    alacritty
    neovim
    git
    wget
    displaylink
    tectonic
    pandoc
    btop-cuda
    element-desktop
    obsidian
    ripgrep
    thunderbird
    gemini-cli
    claude-code
    keepassxc
    signal-desktop
    google-chrome
    mullvad-browser
    lutris
    protontricks
    winetricks
    wineWowPackages.waylandFull
    wineWowPackages.staging
    toybox
    zenity
    protonup
    python3
    zlib
    p7zip
    xournalpp
    sops
    age
    vscode
    libreoffice
  ];
  programs.firefox.enable = true;
  programs.gamescope.enable = true;
  programs.gamemode.enable = true;
  programs.steam.enable = true;
  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    nvidia = {
      open = false;
      nvidiaSettings = false;
      modesetting.enable = true;
      powerManagement.enable = true;
      prime = {
        offload.enable = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    graphics.enable = true;
    system76.enableAll = true;
  };
  services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";


  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/home/sheath/.config/sops/age/keys.txt";
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  system.stateVersion = "25.05";
}
