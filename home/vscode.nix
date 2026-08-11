{ config, pkgs, ... }: {
  # Must be programs.vscodium, not programs.vscode with package = pkgs.vscodium.
  # programs.vscode now unconditionally writes to upstream VS Code's paths
  # (~/.config/Code/User, ~/.vscode/extensions), which VSCodium never reads -- it
  # uses ~/.config/VSCodium/User and ~/.vscode-oss. Under the old wiring every
  # setting and extension below was silently inert.
  programs.vscodium = {
    enable = true;
    # package defaults to pkgs.vscodium for this module; no need to state it.
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
    # The module owns .vscode-oss/argv.json itself; setting it through home.file
    # would collide with argvSettings the moment either side is non-empty.
    argvSettings = {
      enable-crash-reporter = false;
      password-store = "gnome-libsecret";
    };
  };
}
