# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:

{
  imports = [
    ../modules/core.nix
    ../modules/gnome.nix
    ../modules/syncthing.nix
    ../modules/pentest.nix
    "${builtins.fetchGit { url = "https://github.com/NixOS/nixos-hardware.git"; }}/framework/16-inch/7040-amd"
    (import "${builtins.fetchTarball https://github.com/nix-community/home-manager/archive/master.tar.gz}/nixos")
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.kernelParams = [ "amdgpu.abmlevel=0" ];
  boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.extraModulePackages = [ ];
  boot.initrd.luks.devices."luks-3c408b8b-2354-4cc4-8588-2330b9a6caeb".device = "/dev/disk/by-uuid/3c408b8b-2354-4cc4-8588-2330b9a6caeb";
  services.fprintd.enable = false;
  services.logind.lidSwitchExternalPower = "ignore";
  services.fwupd.enable = true;

  # Disk Drives
  fileSystems."/" =
    { device = "/dev/disk/by-uuid/78e901da-2dd2-4dfb-972f-bce345ca9cef";
      fsType = "btrfs";
      options = [ "subvol=@" ];
    };
  boot.initrd.luks.devices."luks-b1ae19ed-ec5e-4436-aa11-f0a046659901".device = "/dev/disk/by-uuid/b1ae19ed-ec5e-4436-aa11-f0a046659901";
  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/36ED-3074";
      fsType = "vfat";
      options = [ "fmask=0077" "dmask=0077" ];
    };
  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/85be3ac4-1be1-445a-b018-37ec1ab44c51";
      fsType = "btrfs";
    };
  swapDevices = [ ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  hardware.keyboard.qmk.enable = true;

  # Graphics
  hardware.graphics.enable = true;

  # Networking
  networking.hostName = "mercury"; # Define your hostname.
  networking.networkmanager.enable = true;
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [ 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];
  hardware.bluetooth.enable = true;

  # Set your time zone.
  time.timeZone = "America/New_York";

  # Select internationalisation properties.
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

  # Enable the X11 windowing system.
  services.xserver.enable = true;
  services.xserver.videoDrivers = [ "amdgpu" ];

  # Enable the GNOME Desktop Environment.
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Syncthing
  systemd.services.syncthing.environment.STNODEFAULTFOLDER = "true"; # Don't create default ~/Sync foldeudo

  # Disable suspend
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.sheath = {
    isNormalUser = true;
    description = "sheath";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
    ];
  };
  home-manager.users.sheath = import ../home/core.nix;

  # Install firefox.
  programs.firefox.enable = true;

  # Install Steam
  programs.steam.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable libvirt
  virtualisation.libvirtd.enable = true;
  programs.virt-manager.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
  system.autoUpgrade.enable = true;
  system.autoUpgrade.allowReboot = false;
  system.autoUpgrade.channel = "https://channels.nixos.org/nixos-24.05";
}
