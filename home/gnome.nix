{ home, pkgs, ... }: {
  home.packages = with pkgs; [
    inconsolata
  ];
  programs.gnome-terminal.profile.default = {
    font = "Inconsolata";
  };
  gtk = {
    enable = true;
    iconTheme = {
      name = "maia-dark";
      package = pkgs.maia-icon-theme;
    };
    theme = {
      name = "Orchis-Dark";
      package = pkgs.orchis-theme;
    };
    cursorTheme = {
      name = "Numix-Cursor";
      package = pkgs.numix-cursor-theme;
    };
    gtk3.extraConfig = {
      Settings = ''
        gtk-application-prefer-dark-theme=1
      '';
    };
    gtk4.extraConfig = {
      Settings = ''
        gtk-application-prefer-dark-theme=1
      '';
    };
  };
  home.sessionVariables.GTK_THEME = "Orchis-Dark";
}
