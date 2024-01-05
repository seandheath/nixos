{ config, pkgs, lib, ... }: {
  imports = [
    ../users/user.nix
  ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "hydrogen"; # Define your hostname.

  # Enable networking
  networking.useDHCP = lib.mkDefault false;
  networking.wireless.enable = false;
  networking.interfaces.enp0s31f6.ipv4.addresses = [{
    address = "10.0.0.2";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.0.0.1";
  networking.nameservers = [ "10.0.0.1" ];
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
    6789
    7878
    8096
    8989
    #14004 # Veloren
  ];
  environment.systemPackages = with pkgs; [
    rustup
    firefox
    git
    curl
    wget
    htop
    tree
    thefuck
    ripgrep
    srm
    vlc
    p7zip
    tmux
    rsync
    go
  ];

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

  # Enable the GNOME Desktop Environment.
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # Configure keymap in X11
  services.xserver = {
    layout = "us";
    xkbVariant = "";
  };

  # Enable sound with pipewire.
  sound.enable = true;
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Enable automatic login for the user.
  services.xserver.displayManager.autoLogin.enable = true;
  services.xserver.displayManager.autoLogin.user = "user";

  # Workaround for GNOME autologin: https://github.com/NixOS/nixpkgs/issues/103746#issuecomment-945091229
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  # Disable suspend
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "no";
  };

  # Enable NVIDIA
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.opengl.enable = true;

  # Enable Syncthing
  services.syncthing.enable = true;

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/f9785601-458e-4fa4-b6e7-4627923f19da";
      fsType = "ext4";
      options = [
        "noatime"
        "nodiratime"
      ];
    };

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/1972-68C4";
      fsType = "vfat";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/07903a2a-35f9-4e70-8296-0f053d1513d0"; }
    ];

  # TODO update once HDDs connected
  fileSystems."/data" =
    {
      device = "/dev/disk/by-uuid/75c4fbbf-7ab0-42f2-b333-31d825d280c2";
      fsType = "btrfs";
      options = [
        "noatime"
        "nodiratime"
        "compress=lzo"
        "discard"
      ];
    };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.11"; # Did you read the comment?
}
