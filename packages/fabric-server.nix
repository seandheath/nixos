{ pkgs }:
# Fabric Loader as a drop-in replacement for the vanilla Minecraft server. Exposes
# bin/minecraft-server taking the same jvmOpts as pkgs.minecraft-server, so
# services.minecraft-server.package points straight at it and the nixpkgs module keeps
# working untouched.
#
# Needed because since 1.21.2 the recipe list and container contents are server-side, so no
# client-only mod can reach them -- see modules/minecraft-server.nix.
#
# NOT the installer jar from meta.fabricmc.net's /server/jar endpoint: that downloads the
# game and its libraries into the working directory on first run, which is neither pure nor
# offline-safe. The launch profile is transcribed here instead -- a main class and eight
# jars, each fetched by URL and hash.
#
# TO UPDATE: curl https://meta.fabricmc.net/v2/versions/loader/<mc>/<loader>/server/json and
# re-transcribe mainClass + libraries. Maven coordinates map to
# <url><group with / for .>/<artifact>/<version>/<artifact>-<version>.jar.
let
  mcVersion = "1.21.10";
  loaderVersion = "0.19.3";

  # net.fabricmc.loader.impl.launch.knot.KnotServer, per the profile above.
  mainClass = "net.fabricmc.loader.impl.launch.knot.KnotServer";

  # Each entry carries its maven coordinate as well as the jar, because the CLIENT
  # profile needs the identical eight jars laid out at their maven paths under
  # libraries/ -- see loaderLibs in passthru and packages/minecraft-client. `path` is
  # the on-disk maven path, which is NOT the URL: '+' is percent-encoded in one and
  # literal in the other.
  loaderLibs = map (l: l // { jar = pkgs.fetchurl (removeAttrs l [ "spec" "path" ]); }) [
    {
      spec = "org.ow2.asm:asm:9.10.1";
      path = "org/ow2/asm/asm/9.10.1/asm-9.10.1.jar";
      name = "asm-9.10.1.jar";
      url = "https://maven.fabricmc.net/org/ow2/asm/asm/9.10.1/asm-9.10.1.jar";
      hash = "sha256-7YJdEKsTmcjAy2aeaIzwyMgmKbTIOZtYNSto6SyhD8s=";
    }
    {
      spec = "org.ow2.asm:asm-analysis:9.10.1";
      path = "org/ow2/asm/asm-analysis/9.10.1/asm-analysis-9.10.1.jar";
      name = "asm-analysis-9.10.1.jar";
      url = "https://maven.fabricmc.net/org/ow2/asm/asm-analysis/9.10.1/asm-analysis-9.10.1.jar";
      hash = "sha256-3t51ohMGtll07Nj4cRT/aXDwn7eUFXpMoJqyXIiMK/w=";
    }
    {
      spec = "org.ow2.asm:asm-commons:9.10.1";
      path = "org/ow2/asm/asm-commons/9.10.1/asm-commons-9.10.1.jar";
      name = "asm-commons-9.10.1.jar";
      url = "https://maven.fabricmc.net/org/ow2/asm/asm-commons/9.10.1/asm-commons-9.10.1.jar";
      hash = "sha256-bQq++3y/ly6hbts37BSDU3JQUGOkX5dqt+qIntlJeJU=";
    }
    {
      spec = "org.ow2.asm:asm-tree:9.10.1";
      path = "org/ow2/asm/asm-tree/9.10.1/asm-tree-9.10.1.jar";
      name = "asm-tree-9.10.1.jar";
      url = "https://maven.fabricmc.net/org/ow2/asm/asm-tree/9.10.1/asm-tree-9.10.1.jar";
      hash = "sha256-PfsNW2oQbNQLWyUOOZNfvy+Sf0R3VGpTaaOsYJzwUGs=";
    }
    {
      spec = "org.ow2.asm:asm-util:9.10.1";
      path = "org/ow2/asm/asm-util/9.10.1/asm-util-9.10.1.jar";
      name = "asm-util-9.10.1.jar";
      url = "https://maven.fabricmc.net/org/ow2/asm/asm-util/9.10.1/asm-util-9.10.1.jar";
      hash = "sha256-G7mdCR+6JZfcbVEZPpu88NhEfn7Za9jwGYsYFS8JZVw=";
    }
    {
      spec = "net.fabricmc:sponge-mixin:0.17.3+mixin.0.8.7";
      path = "net/fabricmc/sponge-mixin/0.17.3+mixin.0.8.7/sponge-mixin-0.17.3+mixin.0.8.7.jar";
      name = "sponge-mixin-0.17.3+mixin.0.8.7.jar";
      url = "https://maven.fabricmc.net/net/fabricmc/sponge-mixin/0.17.3%2Bmixin.0.8.7/sponge-mixin-0.17.3%2Bmixin.0.8.7.jar";
      hash = "sha256-npDv7HHSutW5bJCJ8BnRSoYDIn08X0CNEvU/ronZnUE=";
    }
    {
      spec = "net.fabricmc:intermediary:${mcVersion}";
      path = "net/fabricmc/intermediary/${mcVersion}/intermediary-${mcVersion}.jar";
      name = "intermediary-${mcVersion}.jar";
      url = "https://maven.fabricmc.net/net/fabricmc/intermediary/${mcVersion}/intermediary-${mcVersion}.jar";
      hash = "sha256-0R7NJKk10G1dhN5s6gaAJI9P2wrwHGNWU39lTTCxedM=";
    }
    {
      spec = "net.fabricmc:fabric-loader:${loaderVersion}";
      path = "net/fabricmc/fabric-loader/${loaderVersion}/fabric-loader-${loaderVersion}.jar";
      name = "fabric-loader-${loaderVersion}.jar";
      url = "https://maven.fabricmc.net/net/fabricmc/fabric-loader/${loaderVersion}/fabric-loader-${loaderVersion}.jar";
      hash = "sha256-c+7Yw0u60DIKKjy6U0Y1HoIvdPgrPzwGBXQGhHQTKVg=";
    }
  ];

  libs = map (l: l.jar) loaderLibs;

  vanilla = pkgs.minecraft-server;

  # The vanilla server jar inside the nixpkgs package. Its own launcher runs exactly
  # this file; we hand it to Fabric instead of letting Fabric download its own copy.
  gameJar = "${vanilla}/lib/minecraft/server.jar";

  classpath = pkgs.lib.concatStringsSep ":" (libs ++ [ gameJar ]);

  # Mirror the vanilla package's runtime environment rather than approximating it:
  # nixpkgs' derivation.nix wraps jre_headless (openjdk 21, from the javaVersion in
  # versions.json) and prefixes LD_LIBRARY_PATH with udev. Diverging on either would
  # be a silent behaviour change relative to the server this replaces.
  jre = pkgs.javaPackages.compiler.openjdk21.headless;
in
pkgs.stdenv.mkDerivation {
  pname = "fabric-minecraft-server";
  version = "${mcVersion}-fabric-${loaderVersion}";

  dontUnpack = true;
  preferLocalBuild = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall

    # fabric.gameJarPath: without it Fabric hunts for a server jar in the working
    # directory -- which for us is the world dir -- and aborts. Point it at the store.
    #
    # Flags are APPENDED so the module's jvmOpts (heap sizes, GC flags) still land
    # before them, exactly as in the vanilla wrapper. nogui because this runs headless
    # under systemd with stdin wired to the console FIFO.
    makeWrapper ${pkgs.lib.getExe jre} $out/bin/minecraft-server \
      --append-flags "-Dfabric.gameJarPath=${gameJar}" \
      --append-flags "-cp ${classpath}" \
      --append-flags "${mainClass} nogui" \
      --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.udev ]}

    runHook postInstall
  '';

  passthru = {
    # Consumed by the version-lockstep assertions in modules/minecraft-server.nix.
    # `version` deliberately reports the VANILLA Minecraft version, not the loader's:
    # everything else in this repo compares against it, and code reading .version off
    # a server package means "which Minecraft is this".
    version = vanilla.version;
    inherit mcVersion loaderVersion;
    vanillaPackage = vanilla;

    # The loader's jars with their maven coordinates. packages/minecraft-client builds
    # the CLIENT profile from exactly this list -- Fabric ships the same eight jars for
    # both sides and only the main class differs -- so a loader bump here reaches the
    # clients without a second set of hashes drifting out of step.
    inherit loaderLibs;
  };

  meta = {
    description = "Minecraft server ${mcVersion} with Fabric Loader ${loaderVersion}";
    # Inherited from the game jar this wraps.
    license = pkgs.lib.licenses.unfreeRedistributable;
    platforms = pkgs.lib.platforms.linux;
    mainProgram = "minecraft-server";
  };
}
