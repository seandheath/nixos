{ config, pkgs, ... }: {

  imports = [
    ./core.nix
    ./go.nix
    ./neovim.nix
    ./gnome.nix
  ];

  services.nextcloud-client = {
    enable = true;
    startInBackground = true;
  };

  dconf.settings = {
    "org/gnome/desktop/wm/keybindings" = {
      move-to-workspace-left = [ "<Primary><Shift><Alt>Left" ];
      move-to-workspace-right = [ "<Primary><Shift><Alt>Right" ];
      switch-applications = [ ];
      switch-applications-backward = [ ];
      switch-windows = [ "<Alt>Tab" ];
      switch-windows-backward = [ "<Shift><Alt>Tab" ];
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
        command = "/run/current-system/sw/bin/gnome-terminal";
        name = "open-terminal";
      };
    "org/gnome/desktop/background" = {
      picture-uri = "none";
      primary-color = "0x000000";
      color-shading-type = "solid";
    };
  };
}
