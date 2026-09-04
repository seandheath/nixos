{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
# Ships the offline Minecraft client on any host that plays, and mirrors what it needs into
# a restorable archive on the host that keeps one. Payload is packages/minecraft-client,
# mods packages/minecraft-client-mods.nix, launcher packages/minecraft-client-launcher.nix.
# See docs/minecraft.md.
let
  cfg = config.services.minecraftClient;

  clientMods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };
  client = import ../packages/minecraft-client { inherit pkgs; };
  mcPin = import ../packages/minecraft-version.nix;

  # The launcher hand-transcribes portablemc's CLI; see the version assertion below.
  portablemcVersion = "5.0.3";

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

      # zstd, not the default xz: the bulk is already-compressed jars and oggs, so xz would
      # spend minutes to save little. Append-only on purpose -- an archive that forgets the
      # version you were happily playing is not a restore path. rm -rf and re-run to prune.
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
      example = "mc.luckyobserver.com:25565";
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

    # oneshot + RemainAfterExit so the unit reads "active" and therefore restarts on change.
    # The store paths are baked into the script, so a rebuild that moves the payload changes
    # the unit and switch re-runs it; one that does not is a no-op.
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
      # Pinned independently -- Mojang's manifest and Modrinth -- so nothing else stops them
      # drifting. A mismatch is an incompatible-mods screen, or mods loading against the
      # wrong mappings.
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

      # Fires on EVERY host importing this module, not just the one running a server, and
      # compares against the fleet pin rather than pkgs.minecraft-server -- the laptops have
      # no minecraft-server to read a version from. Without it the payload and the server's
      # actual version diverge, the build succeeds, and the symptom is four children unable
      # to join.
      {
        assertion = client.mcVersion == mcPin.version;
        message = ''
          Minecraft version drift: the fleet pin in packages/minecraft-version.nix is
          ${mcPin.version} but the client payload in packages/minecraft-client is
          ${client.mcVersion}.

          Re-run packages/minecraft-client/update.sh ${mcPin.version}, rebuild to pick
          up the new assets hash, and re-pin the mods. Check upstream support first --
          not every mod tracks a point release promptly.
        '';
      }

      # portablemc's CLI is hand-transcribed into the launcher, so a major bump is a
      # runtime break no build catches -- 4.4.1 -> 5.0.3 moved four flags. Fail loudly
      # at eval instead of at 04:00 on a child's laptop.
      {
        assertion = pkgs.portablemc.version == portablemcVersion;
        message = ''
          portablemc moved from ${portablemcVersion} to ${pkgs.portablemc.version}.
          Re-check the flags in packages/minecraft-client-launcher.nix (--main-dir,
          --mc-dir, --bin-dir, --fetch-exclude-all, --jvm) against the new CLI, then
          bump portablemcVersion in this file.
        '';
      }
    ];
  };
}
