# Far Cry 2 (Proton) modding — operator guide

Declarative setup for **Far Cry 2: Fortune's Edition** (Steam AppID **19900**) with
**Realism+Redux v1.2.5** ("Original Colors, no player position", Nexus Mods #326) +
optional **vkBasalt** CAS sharpening, on host `sulphur`.

The mod download is a **complete, self-contained overlay**: `bin/` + `Data_Win32/` that
already bundles the FoxAhead Multi-Fixer **pre-renamed** for the Steam launch trick
(`bin/FarCry2.exe` = the Multi-Fixer launcher Steam runs; `bin/farcry2game.exe` = the
bootstrapper that loads your game's `Dunia.dll`; `bin/FarCry2MF.dll` + `bin/FarCry2.ini`).
So there is **no separate Multi-Fixer fetch** — we just overlay the whole tree.

Managed by:
- `modules/farcry2.nix` — vkBasalt layers, `vkBasalt.conf`, the `fc2-apply-mods` helper
- `packages/farcry2-realismredux.nix` — the overlay (requireFile, seeded once)

## Non-negotiables

- **You must start a new game** after modding (saves are not cross-compatible).
- **Always DX9** (`Platform="d3d9"`). DX10 crashes — stated by the mod itself.
- **Always cap FPS at 60** — enable "Max Fps" in the Multi-Fixer launcher and/or
  `DXVK_FRAME_RATE=60`. Uncapped FPS **corrupts saves and breaks NPC dialog scripting**.

## One-time seed (why requireFile)

Realism+Redux is Nexus-gated, so its archive is seeded into the Nix store by hand (this is
why the derivation uses `requireFile`, not `fetchurl`). The seeded archive is
`FC2-RealismPlusRedux-326-v1.2.5.7z`, `sha256-X3zot6BpxFmXilDHC1Uu8J1/gZEg+JGRTghD0PqDEi0=`.

To (re)seed — e.g. on a fresh machine after wiping `/nix`:
```sh
# The Nexus filename has spaces; store paths forbid them, so seed a renamed copy:
cp "Realism Plus Redux-326-1-2-5-1696620879.7z" FC2-RealismPlusRedux-326-v1.2.5.7z
nix-store --add-fixed sha256 FC2-RealismPlusRedux-326-v1.2.5.7z
```
If it's missing, the build fails with the `requireFile` message naming this exact file and
hash — that is the intended reinstall reminder.

## Install / apply

```sh
sudo nixos-rebuild switch --flake .#sulphur    # installs fc2-apply-mods + vkBasalt layers
# Install Far Cry 2 (app 19900) via Steam.
fc2-apply-mods                                 # overlay bin/ + Data_Win32/ (hash-guarded, backed up)
```

Then set the **Steam launch options** for app 19900 (Steam UI → Properties; cannot be set
declaratively):
```
ENABLE_VKBASALT=1 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 DXVK_FRAME_RATE=60 %command%
```

Launch via Steam → the **Multi-Fixer launcher** opens. Click **Options** and enable the
mod's recommended set: *Jackal Tapes Fix, Predecessor Tapes Unlock, Machetes Unlock,
No Blinking Items, FOV, Skip Intro Movies, Max Fps*. Press **OK** to play.

After the first launch (which creates the Proton prefix), optionally template the graphics
profile:
```sh
fc2-apply-mods --profile        # writes GamerProfile.xml (2560x1600, DX9, Geometry/Shadows ultra)
```

`fc2-apply-mods` is idempotent — re-running when files already match is a no-op.

## Recovery / reminders

| Situation | Fix |
|---|---|
| Steam "Verify integrity" reverted the mod files | re-run `fc2-apply-mods` (hash guard re-copies) |
| Reinstalled machine / wiped `/nix` — build fails with a `requireFile` message | re-seed (see above), then rebuild |
| Proton prefix regenerated (GamerProfile.xml gone) | re-run `fc2-apply-mods --profile` |
| Undo the mod | `fc2-apply-mods --restore` (restores `.fc2-mod-backup/*.vanilla`; mod-added files like FarCry2MF.dll are left in place) |
| Switched mod version | start a **new game** |

Vanilla backups live in `~/.local/share/Steam/steamapps/common/Far Cry 2/.fc2-mod-backup/`.

## Notes

- **vkBasalt (32-bit):** FC2 is 32-bit, so the 32-bit implicit layer
  (`hardware.graphics.extraPackages32`) is what matters. If sharpening doesn't take effect,
  confirm the layer loads under Steam's pressure-vessel runtime; fallback is to add
  `VK_ADD_LAYER_PATH` / `VKBASALT_CONFIG_FILE` to the launch options. Toggle in-game with
  the `Home` key (see `vkBasalt.conf`). The mod already de-oranges, so vkBasalt does **CAS
  sharpening only** — do not add a color-grade.
- **GamerProfile.xml** is opt-in (`--profile`) because FC2 rewrites it on any in-game options
  change. Set in-game options first, then run `--profile`; the templated file is a starting
  point — verify against a game-generated profile. Default resolution `2560x1600` (GU605MY
  panel), editable in `modules/farcry2.nix`.
- On a dual-GPU laptop, ensure both `FarCry2.exe` and `farcry2game.exe` use the dedicated
  GPU (the mod's own note). Under Proton, `PROTON_FORCE_LARGE_ADDRESS_AWARE=1` + PRIME
  offload handle this.
