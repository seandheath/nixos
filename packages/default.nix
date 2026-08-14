# Local packages, as an overlay. Modules use pkgs.<name> rather than importing paths, so
# these compose with nixpkgs overrides and `nix build .#<name>` works.
#
# `import ... { pkgs = final; }`, not callPackage: these files take a whole pkgs set.
# The Minecraft payload files are absent on purpose -- they are data attrsets or take extra
# arguments, and are imported directly where used.
final: prev: {
  ghidra-reva = import ./ghidra-reva.nix { pkgs = final; };
  imjtool = import ./imjtool.nix { pkgs = final; };
  jackify = import ./jackify.nix { pkgs = final; };
  qwen-code = import ./qwen-code.nix { pkgs = final; };
  re-container = import ./re-container.nix { pkgs = final; };

  # Not a derivation: an attrset of { pythonWithDbus, script, package }, because the
  # systemd unit needs the interpreter and the script separately.
  dock-monitors = import ./dock-monitors.nix { pkgs = final; };
}
