{ pkgs }:

# Container image for the on-demand Minecraft servers the launcher creates
# (packages/minecraft-server-ctl.nix). One image, many containers, one world volume each.
#
# Built from packages/fabric-server.nix rather than a docker.io pull, for the same reason
# packages/re-container.nix is: the server already exists as a pinned Nix package, so the
# image cannot drift from what hydrogen's own minecraft-server.service runs, and nothing is
# fetched at build time. A container world and the shared world are the same build.
#
# Runs as root INSIDE a rootless user namespace, which is the invoking user outside, so the
# bind-mounted world directory needs no `,U` chown and files land owned by that user.
let
  fabricServer = import ./fabric-server.nix { inherit pkgs; };
  mods = import ./minecraft-client-mods.nix { inherit pkgs; };
  datapacks = import ./minecraft-datapacks.nix { inherit pkgs; };
  mcPin = import ./minecraft-version.nix;

  # server.properties is regenerated on every start from the environment, the same way
  # services.minecraft-server's `declarative = true` rewrites it. Edits to the file do not
  # survive a restart; change the container's environment instead.
  #
  # RCON never leaves the container's network namespace -- the control script reaches it
  # with `podman exec`, not over the published port -- so it is a control channel, not an
  # exposed service. It buys a clean `stop` and the save-off/save-all/save-on flush that
  # modules/backup.nix already does for the shared world.
  entrypoint = pkgs.writeShellApplication {
    name = "mc-entrypoint";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = ''
      cd /data

      : "''${MC_RCON_PASSWORD:?the control script must supply one}"
      : "''${MC_MOTD:=minecraft}"
      : "''${MC_DIFFICULTY:=normal}"
      : "''${MC_GAMEMODE:=survival}"
      : "''${MC_MEMORY:=2G}"
      : "''${MC_VIEW_DISTANCE:=10}"

      echo "eula=true" > eula.txt

      cat > server.properties <<EOF
      server-port=25565
      enable-rcon=true
      rcon.port=25575
      rcon.password=''${MC_RCON_PASSWORD}
      broadcast-rcon-to-ops=false
      online-mode=false
      enforce-secure-profile=false
      white-list=false
      motd=''${MC_MOTD}
      difficulty=''${MC_DIFFICULTY}
      gamemode=''${MC_GAMEMODE}
      view-distance=''${MC_VIEW_DISTANCE}
      simulation-distance=8
      max-players=10
      spawn-protection=0
      EOF

      # Delete-then-copy, not symlink: Minecraft >=1.19.4 refuses symlinks in a world dir.
      # Same shape as the preStart in modules/minecraft-server.nix.
      mkdir -p mods world/datapacks
      find mods -maxdepth 1 -name '*.jar' -delete
      cp ${mods.server}/*.jar mods/
      find world/datapacks -maxdepth 1 -name 'vt-*.zip' -delete
      cp ${datapacks}/vt-*.zip world/datapacks/

      exec minecraft-server -Xms1G "-Xmx''${MC_MEMORY}" \
        -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
        -XX:+DisableExplicitGC
    '';
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/minecraft-server";
  tag = mcPin.version;

  contents = [
    fabricServer
    # Reached only via `podman exec`; see the entrypoint note.
    pkgs.mcrcon
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.findutils
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    entrypoint
  ];

  # The world volume is bind-mounted here; the mountpoint has to exist in the image.
  fakeRootCommands = ''
    mkdir -p ./data ./tmp
    chmod 1777 ./tmp
  '';
  enableFakechroot = true;

  config = {
    Entrypoint = [ "/bin/mc-entrypoint" ];
    WorkingDir = "/data";
    ExposedPorts = { "25565/tcp" = { }; };
    Env = [
      "PATH=/bin"
      "HOME=/data"
      "LANG=C.UTF-8"
    ];
  };
}
