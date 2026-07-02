{ config, pkgs, ... }: {
  programs.vscode = {
    enable = true;
    package = pkgs.vscodium;
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        ms-python.python          # debugpy, test runner, env selection (MIT)
        ms-python.debugpy
        detachhead.basedpyright   # open-source language server / type checker
        charliermarsh.ruff        # lint + format
      ];
      userSettings = {
        # Pylance's license forbids running on VSCodium, so stop ms-python from
        # launching it and let basedpyright own the language server instead.
        "python.languageServer" = "None";
        "python.defaultInterpreterPath" = "python";  # picks whatever nix develop puts on PATH
        "basedpyright.analysis.typeCheckingMode" = "standard";
        "[python]" = {
          "editor.defaultFormatter" = "charliermarsh.ruff";
          "editor.formatOnSave" = true;
          "editor.codeActionsOnSave"."source.organizeImports" = "explicit";
        };
        "telemetry.telemetryLevel" = "off";
      };
    };
  };
  home.file.".vscode-oss/argv.json".text = builtins.toJSON {
    enable-crash-reporter = false;
    password-store = "gnome-libsecret";
  };
}
