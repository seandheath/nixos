# Local packages, as an overlay. Modules use pkgs.<name> rather than importing paths, so
# these compose with nixpkgs overrides and `nix build .#<name>` works.
#
# `import ... { pkgs = final; }`, not callPackage: these files take a whole pkgs set.
# The Minecraft payload files are absent on purpose -- they are data attrsets or take extra
# arguments, and are imported directly where used.
final: prev: {
  ghidra-reva = import ./ghidra-reva.nix { pkgs = final; };
  imjtool = import ./imjtool.nix { pkgs = final; };
  installer = import ./installer.nix { pkgs = final; };
  jackify = import ./jackify.nix { pkgs = final; };

  # Hold the jar at the fleet-wide pin rather than whatever the channel ships.
  #
  # This lived in modules/minecraft-server.nix, where it reached hydrogen but not the flake
  # package set -- so `nix build .#minecraft-server-image` got the channel's 26.2, compiled
  # for Java 25, against fabric-server's JDK 21: UnsupportedClassVersionError at runtime,
  # past every assertion. packages/minecraft-version.nix says the version must "not be a
  # property of whichever nixpkgs a host builds from", and this is where that holds.
  minecraft-server = prev.minecraft-server.overrideAttrs (_: rec {
    inherit (import ./minecraft-version.nix) version;
    src = prev.fetchurl { inherit (import ./minecraft-version.nix) url sha1; };
  });

  # Take only pkgs, so unlike the other Minecraft files these fit the overlay. The launcher
  # and the hydrogen module both need them by name.
  minecraft-menu = import ./minecraft-menu { pkgs = final; };
  minecraft-server-image = import ./minecraft-server-image.nix { pkgs = final; };
  minecraft-server-ctl = import ./minecraft-server-ctl.nix { pkgs = final; };
  qwen-code = import ./qwen-code.nix { pkgs = final; };
  re-container = import ./re-container.nix { pkgs = final; };

  # Not a derivation: an attrset of { pythonWithDbus, script, package }, because the
  # systemd unit needs the interpreter and the script separately.
  dock-monitors = import ./dock-monitors.nix { pkgs = final; };
}
