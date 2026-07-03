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

  # Templated GamerProfile.xml. Written only by `fc2-apply-mods --profile` (opt-in)
  # so a working, game-generated profile is never silently clobbered. FC2 REWRITES
  # this file on any in-game options change and on fullscreen toggles — set in-game
  # options first, then run `--profile`, optionally chmod a-w afterwards. Attributes
  # per the research doc + mod instructions: DX9 (Platform="d3d9"), widescreen+FOV,
  # VSync off (cap FPS via Multi-Fixer instead), Geometry/Shadows "ultrahigh" (the
  # mod's recommended settings). This is a STARTING POINT — verify against a profile
  # the game itself generates.
  gamerProfileXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <Profiles Version="16">
      <Profile Name="Default" ProfileVersion="7">
        <RenderProfile ResolutionX="${resX}" ResolutionY="${resY}" Fullscreen="1" RefreshRate="60" VSync="0" ForceWidescreen="1" WidescreenFOV="1" Platform="d3d9">
          <CustomQuality ResolutionX="${resX}" ResolutionY="${resY}">
            <Geometry LodScale="0" id="ultrahigh"/>
            <Shadow id="ultrahigh"/>
            <PostFx DepthOfField="0" MotionBlur="0"/>
          </CustomQuality>
        </RenderProfile>
      </Profile>
    </Profiles>
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
      export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.findutils ]}:$PATH"

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

      # Overlay every file the mod ships (bin/ + Data_Win32/), preserving layout.
      apply_overlay() {
        local src rel
        while IFS= read -r src; do
          rel="''${src#$RR/}"
          copy_guarded "$src" "$GAME_DIR/$rel"
        done < <(find "$RR" -type f)
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
        cat > "$dest" <<'FC2PROFILE'
${gamerProfileXml}FC2PROFILE
        chmod u+w "$dest"
        say "wrote templated GamerProfile.xml (${resX}x${resY}, DX9)"
      }

      case "''${1:-}" in
        --restore) restore; exit 0 ;;
        --profile) PROFILE_ONLY=1 ;;
        "")        PROFILE_ONLY=0 ;;
        *) echo "Usage: fc2-apply-mods [--profile | --restore]"; exit 1 ;;
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

      echo ""
      echo "Overlay applied. Next:"
      echo "  1. Set Steam launch options for app ${appId}:"
      echo "       ENABLE_VKBASALT=1 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 DXVK_FRAME_RATE=60 %command%"
      echo "  2. Launch via Steam: the Multi-Fixer launcher opens — enable Jackal Tapes Fix,"
      echo "     Predecessor/Machetes Unlock, No Blinking Items, FOV, Skip Intro, Max Fps (60-62)."
      echo "  3. After first launch, run 'fc2-apply-mods --profile' to template GamerProfile.xml."
      echo "  Undo with 'fc2-apply-mods --restore'. Start a NEW game. See docs/farcry2.md."
    '')
  ];
}
