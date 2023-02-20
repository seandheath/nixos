{ config, pkgs, ... }:
{

  import = 
  # Desktop Environment
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  services.udev.packages = with pkgs; [
    gnome.gnome-settings-daemon 
  ];

  # GUI Packages
  environment.systemPackages = with pkgs; [
	gnomeExtensions.appindicator
	gnomeExtensions.gtile
	gnome.gnome-tweaks
	gnome.gnome-terminal
  	keepassxc
	vscodium
	nmap
	unzip
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
	ripgrep
	mullvad-vpn
  ];
  environment.sessionVariables.GTK_THEME = "Adwaita:dark";
  environment.etc = {
    "xdg/gtk-2.0/gtkrc".text = ''
      gtk-theme-name = "Adwaita-dark"
      gtk-icon-theme-name = "Adwaita"
    '';
    "xdg/gtk-3.0/settings.ini".text = ''
      [Settings]
      gtk-theme-name = Adwaita-dark
      gtk-application-prefer-dark-theme = true
      gtk-icon-theme-name = Adwaita
    '';

    # Qt4
    "xdg/Trolltech.conf".text = ''
      [Qt]
      style=GTK+
    '';
  };
  qt = {
    enable = true;
    platformTheme = "gnome";
    style = "adwaita-dark";
  };
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

  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };
  programs.steam.enable = true;
  services.pcscd.enable = true;
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  services.mullvad-vpn.enable = true;
}

