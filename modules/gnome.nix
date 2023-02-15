{ config, pkgs, ... }:
{
  virtualisation.oci-containers.backend = "podman";
  virtualisation.podman = {
  	enable = true;
	dockerCompat = true;
  };
  # Desktop Environment
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  services.udev.packages = with pkgs; [
    gnome.gnome-settings-daemon 
  ];
  services.printing.enable = true;
  services.printing.drivers = with pkgs; [
		gutenprint
		gutenprintBin
		brlaser
		brgenml1lpr
  ];
  services.psd.enable = true;

  # GUI Packages
  environment.systemPackages = with pkgs; [
		gnomeExtensions.appindicator
		gnomeExtensions.gtile
		gnome.gnome-tweaks
		gnome.gnome-terminal
		p7zip
		openssl
		profile-sync-daemon
  	keepassxc
		pkg-config
		vscodium
		buildah
		nmap
		unzip
		protonvpn-gui
		vlc
		helix
		nextcloud-client
		tor-browser-bundle-bin
		jellyfin-media-player
		mitmproxy
		wireshark
		discord
		graphviz
		google-chrome
		brasero
		signal-desktop
		filezilla
		pandoc
		tectonic
		tmux
		libreoffice
		go
		joplin-desktop
		bibletime
		teams
		firefox
		bitwarden
		virt-manager
		thefuck
		srm
		ripgrep
		rustup
		gcc
  ];

  environment.gnome.excludePackages = with pkgs; [
    gnome.cheese
    gnome.gnome-music
    gnome.totem
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome.epiphany
    gnome-tour
  ];

  #virtualisation = {
    #libvirtd.enable = true;
    #spiceUSBRedirection.enable = true;
  #};

  programs.steam.enable = true;
  #services.pcscd.enable = true;
  #hardware.pulseaudio.enable = false;
  #security.rtkit.enable = true;
  #services.pipewire = {
    #enable = true;
    #alsa.enable = true;
    #alsa.support32Bit = true;
    #pulse.enable = true;
  #};
}

