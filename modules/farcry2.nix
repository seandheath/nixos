# Far Cry 2 (Steam AppID 19900, Fortune's Edition) modding under Proton.
#
# Reuses the shared gaming stack from steam.nix / workstation.nix / sulphur.nix
# (Steam, Proton-GE, gamescope, gamemode, 32-bit graphics, Vulkan). This module
# adds only the FC2-specific bits:
#   - vkBasalt (32-bit layer) for optional CAS sharpening
#   - a declarative vkBasalt.conf (CAS only — the mod already de-oranges)
#   - `fc2-apply-mods`, a hash-guarded/backed-up installer for the mod overlay
#     (modelled on the steam-winetricks helper in steam.nix)
#
# The mod (packages/farcry2-realismredux.nix, seeded via requireFile) is a complete
# self-contained bin/ + Data_Win32/ overlay that already bundles the Multi-Fixer
# pre-renamed for the Steam launch trick — so there is no separate Multi-Fixer fetch.
# Per the author's instructions we simply overlay the whole tree onto the game dir.
#
# See docs/farcry2.md for Steam launch options and recovery procedures.
{ config, pkgs, lib, inputs, ... }:

let
  realismredux = import ../packages/farcry2-realismredux.nix { inherit pkgs; };

  appId = "19900";

  # Native panel of the Zephyrus GU605MY. Edit here if the default is wrong.
  resX = "2560";
  resY = "1600";

  # WINDOWED by default. Exclusive fullscreen (Fullscreen="1") breaks keyboard/mouse
  # under Wayland — FC2 uses raw input with RIDEV_NOLEGACY and the grab doesn't land
  # in a detached fullscreen window. For fullscreen, deliver it via gamescope in the
  # launch string (see docs/farcry2.md) or Alt+Enter in-game; do NOT set this to "1".
  fullscreen = "0";

  # Templated GamerProfile.xml — the REAL FC2 schema (verified against a profile the
  # game generates), written and locked read-only by `fc2-apply-mods --profile`.
  # Key crash-avoidance settings: DX9 (Platform="d3d9" — DX10 crashes), AA off
  # (MultiSampleMode/AlphaToCoverage=0), VSync off (cap FPS via Multi-Fixer). FC2
  # rewrites this file on any in-game video-options change, flipping Platform back to
  # d3d10a and re-crashing — hence the read-only lock.
  gamerProfileXml = ''
    <GamerProfile>
    	<SoundProfile MusicEnabled="1" MasterVolume="100" />
    	<RenderProfile MultiSampleMode="0" AlphaToCoverage="0" ResolutionX="${resX}" ResolutionY="${resY}" Quality="ultrahigh" Fullscreen="${fullscreen}" Maximized="0" ForceWidescreen="1" WidescreenFOV="1" AspectRatio="0" VSync="0" RefreshRate="60" DisableMip0Loading="0" MaxDriverBufferedFrames="0" Platform="d3d9" ShowFPS="0" ClustersZPassMaxLOD="1" Brightness="1" Contrast="1" GammaRamp="1" GammaRampR="1" GammaRampG="1" GammaRampB="1" AllowAsynchShaderLoading="1">
    		<CustomQuality>
    			<quality ResolutionX="800" ResolutionY="600" EnvironmentQuality="high" AntiPortalQuality="high" PostFxQuality="high" TextureQuality="high" TextureResolutionQuality="high" WaterQuality="high" DepthPassQuality="high" VegetationQuality="high" TerrainQuality="high" GeometryQuality="high" AmbientQuality="high" ShadowQuality="high" Hdr="1" HdrFP32="0" Bloom="1" id="custom" />
    		</CustomQuality>
    	</RenderProfile>
    	<NetworkProfile CustomMapMaxUploadRateOnline="10240" OnlineEnginePort="9000" OnlineServicePort="9001" FileTransferHostPort="9002" FileTransferClientPort="9003" LanBroadcastPort="9004" ScanFreePorts="1" ScanPortRange="1000" ScanPortStart="9000" SessionProvider="" DetectPublicAddress="1" MaxUploadOnline="768">
    		<Accounts />
    	</NetworkProfile>
    	<GameProfile Sensitivity="0.9" Invert_y="0" UseMouseSmooth="0" Smoothness="1" Smoothness_Ironsight="1" HelpCrosshair="0" UseCompassMiniMap="1" UseRoadSignHilight="1" UseSubtitles="1" UseAmbx="0" Autosave="1" Machete="0" DifficultyLevel="2" ClanTag="">
    		<FireConfig QualitySetting="VeryHigh" />
    	</GameProfile>
    	<RealTreeProfile Quality="VeryHigh">
    		<CustomQuality />
    	</RealTreeProfile>
    	<EngineProfile>
    		<PhysicConfig QualitySetting="VeryHigh" />
    		<QcConfig GatherFPS="1" GatherAICnt="1" IsQcTester="0" />
    		<InputConfig />
    	</EngineProfile>
    </GamerProfile>
  '';

  # Minimal, targeted KeyValues editor: sets (or inserts) the "LaunchOptions" key
  # inside apps -> <appid> in a Steam localconfig.vdf. Brace-depth matched so it
  # only touches the right block. VDF-escapes the value (\\ and \"). argv:
  # <localconfig.vdf> <appid> <launch-options-string>.
  setLaunchOptsPy = pkgs.writeText "fc2-set-launch-opts.py" ''
    import sys, re
    path, appid, opts = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    def find_block(key, start, end):
        keypat = re.compile(r'^\s*"' + re.escape(key) + r'"\s*$')
        i = start
        while i < end:
            if keypat.match(lines[i]):
                j = i + 1
                while j < end and lines[j].strip() == "":
                    j += 1
                if j < end and lines[j].strip() == "{":
                    depth, k = 0, j
                    while k < end:
                        depth += lines[k].count("{") - lines[k].count("}")
                        if depth == 0:
                            return (j, k)
                        k += 1
            i += 1
        return None

    apps = find_block("apps", 0, len(lines))
    if not apps:
        sys.exit("no apps section in " + path)
    app = find_block(appid, apps[0] + 1, apps[1])
    if not app:
        sys.exit(appid + " block not found - install/run the game once first")
    o, c = app
    val = '"' + opts.replace("\\", "\\\\").replace('"', '\\"') + '"'
    lo = re.compile(r'^(\s*)"LaunchOptions"\s+".*"\s*$')
    done = False
    for idx in range(o + 1, c):
        m = lo.match(lines[idx])
        if m:
            lines[idx] = m.group(1) + '"LaunchOptions"\t\t' + val + "\n"
            done = True
            break
    if not done:
        lines.insert(o + 1, "\t\t\t\t\t" + '"LaunchOptions"\t\t' + val + "\n")
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
  '';
in
{
  # --- vkBasalt: install both arch layers. FC2 is a 32-bit game, so the 32-bit
  # implicit-layer JSON (extraPackages32) is the one that actually matters; these
  # merge with the hardware.graphics block in hosts/sulphur.nix. Enable per-game
  # with ENABLE_VKBASALT=1 in the Steam launch options (see docs/farcry2.md).
  hardware.graphics.extraPackages   = [ pkgs.vkbasalt ];
  hardware.graphics.extraPackages32 = [ pkgs.pkgsi686Linux.vkbasalt ];

  # Conservative CAS sharpening only. The mod fixes colors internally, so we do NOT
  # add a color-grade here (stacking would over-process). `.force` because vkBasalt
  # co-owns this path at runtime (repo convention, cf. wivrn.nix).
  home-manager.users.sheath.xdg.configFile."vkBasalt/vkBasalt.conf" = {
    force = true;
    text = ''
      effects = cas
      casSharpness = 0.4
      # Toggle key (default HOME) to enable/disable in-game.
      toggleKey = Home
      enableOnLaunch = True
    '';
  };

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "fc2-apply-mods" ''
      set -euo pipefail
      export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.procps ]}:$PATH"

      GAME_DIR="$HOME/.local/share/Steam/steamapps/common/Far Cry 2"
      BACKUP_DIR="$GAME_DIR/.fc2-mod-backup"
      RR="${realismredux}"
      PREFIX="$HOME/.local/share/Steam/steamapps/compatdata/${appId}/pfx"
      PROFILE_DIR="$PREFIX/drive_c/users/steamuser/Documents/My Games/Far Cry 2"

      say()   { echo "  $*"; }
      hashf() { sha256sum "$1" | cut -d' ' -f1; }

      # copy_guarded <src> <dest-abs>: back up vanilla once, copy only if changed.
      copy_guarded() {
        local src="$1" dest="$2" rel bak
        rel="''${dest#$GAME_DIR/}"
        if [ -f "$dest" ] && [ "$(hashf "$src")" = "$(hashf "$dest")" ]; then
          say "= $rel (up to date)"
          return 0
        fi
        if [ -f "$dest" ]; then
          bak="$BACKUP_DIR/$rel.vanilla"
          mkdir -p "$(dirname "$bak")"
          if [ ! -e "$bak" ]; then
            cp -p "$dest" "$bak"
            say "backed up vanilla $rel -> .fc2-mod-backup/"
          fi
        fi
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        chmod u+w "$dest"          # store files are read-only 0444
        say "+ $rel"
      }

      # Overlay the mod's bin/ + Data_Win32/, but DE-COLLIDE the two exes. The mod
      # ships the Multi-Fixer launcher AS FarCry2.exe and the real game AS
      # farcry2game.exe (a Windows launch trick). Under Proton that self-naming makes
      # the launcher's game auto-detection target itself → "Dll not loaded" + runtime
      # error 218. So we install the game as FarCry2.exe (Steam's registered exe) and
      # the launcher as FarCry2MFLauncher.exe (run explicitly via the Proton launch
      # string in --set-launch-opts).
      apply_overlay() {
        local src rel dest
        while IFS= read -r src; do
          rel="''${src#$RR/}"
          case "$rel" in
            bin/FarCry2.exe)     dest="$GAME_DIR/bin/FarCry2MFLauncher.exe" ;;
            bin/farcry2game.exe) dest="$GAME_DIR/bin/FarCry2.exe" ;;
            *)                   dest="$GAME_DIR/$rel" ;;
          esac
          copy_guarded "$src" "$dest"
        done < <(find "$RR" -type f)
        # Drop the redundant mod game-exe name so the launcher can't pick a 2nd
        # candidate (harmless duplicate, but keep the layout clean).
        rm -f "$GAME_DIR/bin/farcry2game.exe"
      }

      # Short-path symlink C:\FC2 -> game dir inside the Proton prefix. The MF launcher
      # computes the injected DLL path relative to its own module location; a short
      # C: path avoids a Wine LoadLibrary failure on the long Z:\home\... path. Only
      # created once the prefix exists (i.e. after the game's first Steam launch).
      ensure_symlink() {
        if [ -d "$PREFIX/drive_c" ] && [ ! -e "$PREFIX/drive_c/FC2" ]; then
          ln -s "$GAME_DIR" "$PREFIX/drive_c/FC2"
          say "created prefix symlink C:\\FC2 -> game dir"
        fi
      }

      restore() {
        if [ ! -d "$BACKUP_DIR" ]; then
          echo "No backups found at $BACKUP_DIR — nothing to restore." >&2
          exit 1
        fi
        echo "Restoring vanilla files from $BACKUP_DIR ..."
        local rel dest_rel
        while IFS= read -r rel; do
          rel="''${rel#./}"
          dest_rel="''${rel%.vanilla}"
          cp "$BACKUP_DIR/$rel" "$GAME_DIR/$dest_rel"
          chmod u+w "$GAME_DIR/$dest_rel"
          say "restored $dest_rel"
        done < <(cd "$BACKUP_DIR" && find . -name '*.vanilla')
        echo "Done. Note: mod-added files with no vanilla original (e.g. FarCry2MF.dll,"
        echo "farcry2game.exe) are left in place; delete them manually if desired."
      }

      write_profile() {
        if [ ! -d "$PREFIX" ]; then
          echo "Proton prefix for app ${appId} not found — launch FC2 once via Steam first." >&2
          exit 1
        fi
        mkdir -p "$PROFILE_DIR"
        local dest="$PROFILE_DIR/GamerProfile.xml"
        if [ -f "$dest" ] && [ ! -e "$dest.vanilla" ]; then
          cp -p "$dest" "$dest.vanilla"
          say "backed up existing GamerProfile.xml"
        fi
        [ -f "$dest" ] && chmod u+w "$dest" || true   # may be locked from a prior run
        cat > "$dest" <<'FC2PROFILE'
${gamerProfileXml}FC2PROFILE
        # Lock read-only: FC2 rewrites this to DX10 on any in-game video-options
        # change, which re-crashes. To change settings later: chmod u+w, edit, re-lock.
        chmod a-w "$dest"
        say "wrote + locked GamerProfile.xml (${resX}x${resY}, DX9, windowed)"
      }

      # Write the known-good Proton launch string into Steam's per-app launch options
      # (localconfig.vdf). Steam rewrites that file on exit, so it MUST be closed —
      # we detect a running Steam and offer to shut it down or abort.
      # Returns 0 on success, non-zero if skipped/failed (so callers can treat it as
      # a soft step). Never uses `exit` — the main apply must still succeed even if
      # launch options are skipped.
      set_launch_opts() {
        local PROTON LAUNCHER OPTS ans ans2 vdf found=0 i
        # Newest installed GE-Proton. The launch string embeds an absolute proton
        # path, so this is re-run on every `fc2-apply-mods` (picks up GE updates).
        PROTON="$(ls -d "$HOME"/.steam/root/compatibilitytools.d/GE-Proton*/proton 2>/dev/null | sort -V | tail -1 || true)"
        if [ -z "$PROTON" ]; then
          echo "  ! No GE-Proton under ~/.steam/root/compatibilitytools.d/ - launch options not set." >&2
          return 1
        fi
        # Launcher path uses the drive_c/FC2 short-path symlink (ensure_symlink).
        # If the symlink proves unnecessary, switch to "$GAME_DIR/bin/FarCry2MFLauncher.exe".
        LAUNCHER="$PREFIX/drive_c/FC2/bin/FarCry2MFLauncher.exe"
        OPTS="WINEDLLOVERRIDES=\"winegstreamer=\" ENABLE_VKBASALT=1 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 DXVK_FRAME_RATE=60 \"$PROTON\" run \"$LAUNCHER\" # %command%"

        if pgrep -x steam >/dev/null 2>&1; then
          echo "Steam is running; it rewrites localconfig.vdf on exit, so it must be"
          echo "closed before setting launch options."
          printf "Shut down Steam now? [y]es / [N]o (skip launch options): "
          read -r ans || ans=""
          case "''${ans:-}" in
            y|Y|yes|YES)
              echo "Requesting graceful Steam shutdown..."
              steam -shutdown >/dev/null 2>&1 || true
              for i in $(seq 1 20); do pgrep -x steam >/dev/null 2>&1 || break; sleep 1; done
              if pgrep -x steam >/dev/null 2>&1; then
                printf "Steam still running after 20s. Force-kill it? [y]es / [N]o: "
                read -r ans2 || ans2=""
                case "''${ans2:-}" in
                  y|Y|yes|YES)
                    pkill -TERM -x steam 2>/dev/null || true; sleep 2
                    pkill -KILL -x steam 2>/dev/null || true; sleep 1 ;;
                  *) echo "  ! Steam still running - launch options not set."; return 1 ;;
                esac
              fi
              echo "Steam stopped." ;;
            *)
              echo "  ! Skipped launch options. Set later: fc2-apply-mods --set-launch-opts"
              return 1 ;;
          esac
        fi

        for vdf in "$HOME"/.local/share/Steam/userdata/*/config/localconfig.vdf; do
          [ -f "$vdf" ] || continue
          found=1
          cp -p "$vdf" "$vdf.fc2-bak"
          if ${pkgs.python3}/bin/python3 ${setLaunchOptsPy} "$vdf" "${appId}" "$OPTS"; then
            say "set launch options in $vdf"
          else
            echo "  ! Failed editing $vdf - restored from backup." >&2
            cp -p "$vdf.fc2-bak" "$vdf"
            return 1
          fi
        done
        if [ "$found" != 1 ]; then
          echo "  ! No localconfig.vdf yet (log into Steam once) - launch options not set." >&2
          return 1
        fi
        say "launch options set for app ${appId}"
        return 0
      }

      case "''${1:-}" in
        --restore)         restore; exit 0 ;;
        --profile)         PROFILE_ONLY=1 ;;
        --set-launch-opts) set_launch_opts && exit 0 || exit 1 ;;
        "")                PROFILE_ONLY=0 ;;
        *) echo "Usage: fc2-apply-mods [--profile | --restore | --set-launch-opts]"; exit 1 ;;
      esac

      if [ ! -d "$GAME_DIR" ]; then
        echo "Far Cry 2 not found at:" >&2
        echo "  $GAME_DIR" >&2
        echo "Install app ${appId} via Steam first." >&2
        exit 1
      fi

      if [ "''${PROFILE_ONLY:-0}" = "1" ]; then
        echo "Writing GamerProfile.xml only..."
        write_profile
        exit 0
      fi

      echo "Applying Far Cry 2: Realism+Redux overlay to:"
      echo "  $GAME_DIR"
      apply_overlay
      ensure_symlink

      # Automatically set the Steam launch options too (soft: the overlay above has
      # already succeeded, so a skip/failure here is a warning, not a hard error).
      echo ""
      echo "Setting Steam launch options..."
      set_launch_opts || true

      echo ""
      echo "Done. Next:"
      echo "  1. Launch via Steam: the Multi-Fixer launcher opens — enable Jackal Tapes Fix,"
      echo "     Predecessor/Machetes Unlock, No Blinking Items, FOV, Skip Intro, Max Fps (60),"
      echo "     and set the processor-affinity mask (15 = 4 cores) for many-core stability."
      echo "  2. After first launch, run 'fc2-apply-mods --profile' to template GamerProfile.xml."
      echo "  (Launch options are set automatically above; re-run --set-launch-opts alone if you"
      echo "   skipped closing Steam.) Undo with '--restore'. Start a NEW game. See docs/farcry2.md."
    '')
  ];
}
