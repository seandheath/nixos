{ config, pkgs, ... }: {
  dconf.settings = {
    "org/gnome/SessionManager" = {
      logout-prompt = false;
    };
    "org/gnome/shell" = {
      favorite-apps = [
        "org.gnome.Nautilus.desktop"
        "firefox.desktop"
        "org.keepassxc.KeePassXC.desktop"
      ];
    };
    "org/gnome/mutter" = {
      attach-modal-dialogs = false;
    };
    "org/gnome/desktop/background" = {
      picture-uri = "none";
      picture-uri-dark = "none";
      primary-color = "0x000000";
      color-shading-type = "solid";
    };
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      enable-hot-corners = false;
      font-hinting = "slight";
      font-antialiasing = "grayscale";
      gtk-theme = "Adwaita-dark";
    };
    "org/gnome/desktop/sound" = {
      allow-volume-above-100-percent = true;
    };
    "org/gnome/shell" = {
      disable-user-extensions = false;
      disable-extension-version-validation = true;
      enabled-extensions = [
        "appindicatorsupport@rgcjonas.gmail.com"
        "gTile@vibou"
        "launch-new-instance@gnome-shell-extensions.gcampax.github.com"
        "workspace-indicator@gnome-shell-extensions.gcampax.github.com"
        "bluetooth-quick-connect@bjarosze.gmail.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "eepresetselector@ulville.github.io"
	"Vitals@CoreCoding.com"
      ];
    };
    "org/gnome/desktop/peripherals/touchpad" = {
      tap-to-click = true;
      natural-scroll = true;
    };
    "org/gnome/desktop/wm/keybindings" = {
      move-to-workspace-left = [ "<Primary><Shift><Alt>Left" ];
      move-to-workspace-right = [ "<Primary><Shift><Alt>Right" ];
      switch-applications = [ ];
      switch-applications-backward = [ ];
      switch-windows = [ "<Alt>Tab" ];
      switch-windows-backward = [ "<Shift><Alt>Tab" ];
    };
    "org/gnome/desktop/wm/preferences" = {
      button-layout = "appmenu:minimize,maximize,close";
      titlebar-font = "Inconsolata Bold 11";
    };
    "org/gnome/settings-daemon/plugins/media-keys" = {
      custom-keybindings = [
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
      ];
      home = [ "<Super>e" ];
      area-screenshot-clip = [ ];
    };
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" =
      {
        binding = "<Alt>Return";
        command = "/home/sheath/.nix-profile/bin/alacritty";
        name = "open-terminal";
      };
    "org/gnome/germinal/legacy".theme-variant = "dark";
  };

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}
