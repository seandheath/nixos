{ pkgs, ... }: {
  programs.alacritty = {
    enable = true;
    settings = {
      font.normal.family = "Inconsolata";
      font.size = 14.0;
      colors.primary.background = "#000000";
      # Selection feeds middle-click paste without replacing the regular clipboard.
      selection.save_to_clipboard = false;
      # home.sessionPath is loaded by ~/.profile, so use a login shell.
      terminal.shell = {
        program = "${pkgs.bashInteractive}/bin/bash";
        args = [ "--login" ];
      };
    };
  };

  home.packages = [ pkgs.inconsolata pkgs.adwaita-fonts ];

  # Codex's prompt sparkles use Braille dots, which Inconsolata lacks.
  fonts.fontconfig.configFile.inconsolata-fallback = {
    enable = true;
    priority = 52;
    text = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
      <fontconfig>
        <alias>
          <family>Inconsolata</family>
          <accept><family>Adwaita Mono</family></accept>
        </alias>
      </fontconfig>
    '';
  };

  xdg.terminal-exec = {
    enable = true;
    settings = {
      default = [ "Alacritty.desktop" ];
      GNOME = [ "Alacritty.desktop" ];
    };
  };
}
