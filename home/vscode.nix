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
        llvm-vs-code-extensions.vscode-clangd  # C/C++ language server client
        teabyii.ayu               # Ayu color themes
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
        # Pin clangd to the nix-store binary (same clang-tools neovim uses) so the
        # extension never tries to auto-download a dynamically-linked clangd, which
        # can't run on NixOS. clang-tools ships clangd/clang-format/clang-tidy.
        "clangd.path" = "${pkgs.clang-tools}/bin/clangd";
        "clangd.onConfigChanged" = "restart";
        "clangd.checkUpdates" = false;  # binary is nix-managed; suppress update nagging
        "telemetry.telemetryLevel" = "off";
        "workbench.colorTheme" = "Ayu Dark Bordered";
        "claudeCode.preferredLocation" = "panel";
      };
    };
  };
  home.file.".vscode-oss/argv.json".text = builtins.toJSON {
    enable-crash-reporter = false;
    password-store = "gnome-libsecret";
  };
}
