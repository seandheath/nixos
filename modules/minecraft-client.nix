{
  config,
  pkgs,
  lib,
  ...
}:
# Ships the offline Minecraft client on any host that plays, and mirrors everything it
# needs into a restorable archive on the host that keeps one.
#
# Imported by hosts/hydrogen.nix (the couch clients, via modules/minecraft-couch.nix)
# and hosts/sulfur.nix (the desktop client). The game payload is
# packages/minecraft-client, the mods packages/minecraft-client-mods.nix, and the
# launcher packages/minecraft-client-launcher.nix; see docs/minecraft.md.
#
# WHAT THIS REPLACED, and why. Until 2026-08-05 both hosts ran Prism Launcher, and this
# module (as modules/minecraft-mods.nix) did one job: keep a hand-created Prism
# instance's mods folder symlinked at the Nix-managed jar set. Everything else the game
# needed -- the client jar, 115 libraries, 424 MiB of assets, a JVM, and the cached
# Microsoft account that made `--offline` work at all -- was undeclared state that Prism
# refetched from Mojang, excluded from the backups as "re-downloadable". That is a
# playable setup only for as long as Mojang keeps serving it. Now every byte is pinned
# in the flake, so the client can be rebuilt from source of truth, and archived.
let
  cfg = config.services.minecraftClient;

  clientMods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };
  client = import ../packages/minecraft-client { inherit pkgs; };

  launcher = import ../packages/minecraft-client-launcher.nix {
    inherit pkgs;
    defaultName = cfg.playerName;
    defaultServer = cfg.server;
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "minecraft-client";
    desktopName = "Minecraft";
    comment = "Minecraft ${client.mcVersion} (Fabric)"
      + lib.optionalString (cfg.server != null) " on ${cfg.server}";
    exec = lib.getExe launcher;
    icon = "input-gaming";
    categories = [ "Game" ];
    terminal = false;
  };

  # Everything a restore needs, as store paths. The launcher's closure already contains
  # the payload, the mods, portablemc and the JDK; the server side is listed separately
  # because hydrogen keeps the world as well as the clients.
  archivePaths =
    [ launcher ]
    ++ lib.optionals config.services.minecraft-server.enable [
      config.services.minecraft-server.package
      (import ../packages/minecraft-datapacks.nix { inherit pkgs; })
      clientMods.server
    ];

  archive = pkgs.writeShellApplication {
    name = "minecraft-archive";
    runtimeInputs = [ config.nix.package pkgs.coreutils ];
    text = ''
      mkdir -p ${cfg.archiveDir}

      # A plain local binary cache. zstd rather than the default xz: the bulk of this
      # is already-compressed jars and oggs, so xz would spend minutes to save little.
      # ~1.6 GB on disk -- the client closure is 1.9 GiB (538 MiB of game payload, the
      # rest JDK, python and portablemc) and the server another 673 MiB, overlapping.
      #
      # Append-only. Old payloads stay behind after a version bump, which is the point
      # -- an archive that forgets the version you were happily playing is not a
      # restore path. `rm -rf ${cfg.archiveDir}` and re-run to prune.
      nix copy --to "file://${cfg.archiveDir}?compression=zstd" \
        ${lib.escapeShellArgs (map toString archivePaths)}

      echo "minecraft-archive: $(du -sh ${cfg.archiveDir} | cut -f1) in ${cfg.archiveDir}"
    '';
  };
in
{
  options.services.minecraftClient = {
    enable = lib.mkEnableOption "the offline Minecraft client";

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = launcher;
      defaultText = lib.literalMD "the `minecraft-client` wrapper built from this host's settings";
      description = ''
        The launcher this host ships, exposed so other modules can invoke the exact
        same build rather than importing the package a second time with arguments that
        can drift. modules/minecraft-couch.nix runs it once per player.
      '';
    };

    playerName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "LuckyObserver";
      description = ''
        Default Minecraft username, used when `minecraft-client` is run without
        `--name`. Offline UUIDs derive from a hash of the name, so renaming a player
        who has already played orphans that character. Overridden per invocation by
        `--name` or `$MINECRAFT_USERNAME`, which is how the couch launcher gives each
        child their own identity.
      '';
    };

    server = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.0.0.10:25565";
      description = ''
        Server to connect to on launch, `HOST` or `HOST:PORT`. The client quick-plays
        straight into it, so no server list is involved. Null starts at the main menu.
      '';
    };

    desktopEntry = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install a "Minecraft" application launcher. Off on hosts whose entry point is
        something else -- hydrogen's is "Minecraft (Couch)" in modules/minecraft-couch.nix.
      '';
    };

    archiveDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/minecraft-archive";
      description = ''
        Mirror the client and server closures into a local Nix binary cache at this
        path, refreshed on every switch that changes them. This is the copy that makes
        a restore independent of Mojang and Modrinth still being there; include it in
        the backups (modules/backup.nix). Null disables the archive.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ launcher ] ++ lib.optional cfg.desktopEntry desktopItem;

    # ---------------------------------------------------------------------------
    # The archive.
    #
    # Type=oneshot + RemainAfterExit so the unit is "active" after a successful run and
    # therefore actually restarts on change -- and because the store paths are baked
    # into the script, a rebuild that changes the payload changes the unit, and switch
    # re-runs it. A rebuild that does not is a no-op. Same trick the old
    # minecraft-mods-link.service used.
    # ---------------------------------------------------------------------------
    systemd.services.minecraft-archive = lib.mkIf (cfg.archiveDir != null) {
      description = "Mirror the Minecraft payload into a restorable local binary cache";
      wantedBy = [ "multi-user.target" ];
      after = [ "nix-daemon.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe archive;

        # ~540 MiB of copying, and nothing waits on it.
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    assertions = [
      # The payload and the mods are pinned independently -- one from Mojang's version
      # manifest, one from Modrinth -- so nothing but this stops them drifting apart.
      # A mismatch is a Fabric "incompatible mods" screen at launch, or worse, mods
      # that load and then misbehave against the wrong mappings.
      {
        assertion = client.mcVersion == clientMods.mcVersion;
        message = ''
          Minecraft version drift: the client payload in packages/minecraft-client is
          ${client.mcVersion} but the mods in packages/minecraft-client-mods.nix are
          pinned to ${clientMods.mcVersion}.

          Re-run packages/minecraft-client/update.sh for the version you want, then
          re-pin the mods (that file's header has the Modrinth query).
        '';
      }
    ]
    # Only meaningful where the server actually is. sulfur has no minecraft-server to
    # compare against, but it consumes the same payload, so hydrogen failing to build
    # is enough to catch the drift for both.
    #
    # The failure this prevents: a nixpkgs bump moves minecraft-server past 1.21.10
    # while the pinned client stays put. Without this the build succeeds and the
    # symptom is four children unable to join.
    ++ lib.optionals config.services.minecraft-server.enable [
      {
        assertion = pkgs.minecraft-server.version == client.mcVersion;
        message = ''
          Minecraft version drift: the server is ${pkgs.minecraft-server.version} but the
          client payload in packages/minecraft-client is ${client.mcVersion}.

          Re-run packages/minecraft-client/update.sh ${pkgs.minecraft-server.version},
          rebuild to pick up the new assets hash, and re-pin the mods. Check upstream
          support first -- not every mod tracks a point release promptly.
        '';
      }
    ];
  };
}
