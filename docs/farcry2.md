# Far Cry 2 (Proton) modding — operator guide

Declarative-ish setup for **Far Cry 2: Fortune's Edition** (Steam AppID **19900**) with
**Realism+Redux v1.2.5** ("Original Colors, no player position", Nexus Mods #326) + the
bundled **FoxAhead Multi-Fixer**, running under **GE-Proton**, on host `sulfur`.

Managed by:
- `modules/farcry2.nix` — vkBasalt 32-bit layer + `vkBasalt.conf`, and the `fc2-apply-mods` helper
- `packages/farcry2-realismredux.nix` — the mod overlay (requireFile, seeded once)

## TL;DR — install

```sh
sudo nixos-rebuild switch --flake .#sulfur     # installs fc2-apply-mods + vkBasalt
# Install Far Cry 2 (app 19900) via Steam and launch it ONCE (creates the Proton prefix), quit.
fc2-apply-mods                                   # overlay + symlink + sets Steam launch options
```

`fc2-apply-mods` (no args) does everything: applies the mod overlay, creates the prefix
symlink, and writes the Steam launch options. If Steam is running it offers to shut it down
first (launch options live in `localconfig.vdf`, which Steam rewrites on exit).

Then launch via Steam → the **Multi-Fixer launcher** opens → **Options** → enable:
*Jackal Tapes Fix, Predecessor Tapes Unlock, Machetes Unlock, No Blinking Items, FOV, Skip
Intro Movies, Max Fps (60)*, and set the **processor-affinity mask to `15`** (4 cores — FC2
crashes on many-core CPUs; you have 16). Press **Play**. **Start a new game.**

## The layout `fc2-apply-mods` produces

The mod ships the launcher *as* `FarCry2.exe` and the game *as* `farcry2game.exe` (a Windows
launch trick). That self-naming breaks the Multi-Fixer's game auto-detection under Proton, so
the overlay **de-collides** them:

| file | what it is |
|---|---|
| `bin/FarCry2.exe` | the **game** (Steam's registered exe; the launcher's inject target) |
| `bin/FarCry2MFLauncher.exe` | the **Multi-Fixer launcher** (run explicitly via the launch string) |
| `bin/FarCry2MF.dll` | the fix DLL |
| `Data_Win32/patch.{dat,fat}` | the overhaul data |
| `compatdata/19900/pfx/drive_c/FC2` | symlink → game dir (short `C:\FC2` path, see below) |

## The launch string (set automatically)

`fc2-apply-mods` writes this into Steam's launch options for app 19900 (newest GE-Proton is
auto-detected):

```
WINEDLLOVERRIDES="winegstreamer=" ENABLE_VKBASALT=1 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 DXVK_FRAME_RATE=60 "<GE-Proton>/proton" run "<prefix>/drive_c/FC2/bin/FarCry2MFLauncher.exe" # %command%
```

Re-run `fc2-apply-mods` (or `fc2-apply-mods --set-launch-opts`) after a **GE-Proton update**,
since the string embeds an absolute proton path.

## Non-negotiables (each maps to a fix baked into the setup)

- **DX9 only** (`Platform="d3d9"`). DX10 crashes. `fc2-apply-mods --profile` writes and
  **locks** `GamerProfile.xml` read-only so FC2 can't rewrite it back to DX10.
- **Cap FPS at 60** (Multi-Fixer *Max Fps* + `DXVK_FRAME_RATE=60`). Uncapped FPS corrupts saves.
- **`winegstreamer` disabled** (`WINEDLLOVERRIDES="winegstreamer="`). GE's `winegstreamer`
  stubs `create_color_converter`, so the game **hard-aborts on the intro videos** without this.
- **Windowed, not exclusive fullscreen.** FC2 uses raw input with `RIDEV_NOLEGACY`; the grab
  doesn't land in a detached exclusive-fullscreen window under Wayland → **no keyboard/mouse**.
  The profile template defaults to `Fullscreen="0"`.
- **Processor-affinity mask 15** in the Multi-Fixer (4 cores) — FC2 crashes on 16 cores.
- **Short `C:\FC2` path** (the prefix symlink). The launcher builds the injected DLL path
  relative to its own location; the long `Z:\home\...` path fails `LoadLibrary` under Wine.

## Fullscreen

Exclusive fullscreen breaks input (above), so the profile stays windowed. For fullscreen:
- **Alt+Enter in-game** (the input grab is already established in the window), or
- wrap the launch in **gamescope** (fullscreen with input handled by gamescope):
  ```
  ... DXVK_FRAME_RATE=60 gamescope -W 2560 -H 1600 -f --force-grab-cursor -- "<GE-Proton>/proton" run "<prefix>/drive_c/FC2/bin/FarCry2MFLauncher.exe" # %command%
  ```

## One-time seed (why requireFile)

Realism+Redux is Nexus-gated, so its archive is seeded into the Nix store by hand. Seeded
name `FC2-RealismPlusRedux-326-v1.2.5.7z`, `sha256-X3zot6BpxFmXilDHC1Uu8J1/gZEg+JGRTghD0PqDEi0=`.
To (re)seed on a fresh machine:
```sh
cp "Realism Plus Redux-326-1-2-5-1696620879.7z" FC2-RealismPlusRedux-326-v1.2.5.7z   # store paths forbid spaces
nix-store --add-fixed sha256 FC2-RealismPlusRedux-326-v1.2.5.7z
```
If missing, the build fails with the `requireFile` message naming this file/hash — the reinstall reminder.

## Recovery

| Situation | Fix |
|---|---|
| Steam "Verify integrity" reverted files | re-run `fc2-apply-mods` (repairs layout, re-sets launch opts) |
| Reinstalled / wiped `/nix` — build fails with a `requireFile` message | re-seed (above), rebuild |
| GE-Proton updated (launch string points at old path) | `fc2-apply-mods --set-launch-opts` |
| Proton prefix regenerated (GamerProfile / symlink gone) | re-run `fc2-apply-mods` |
| Game crashes at the intro | confirm `WINEDLLOVERRIDES="winegstreamer="` is in the launch options |
| Crash to desktop on launch | confirm `Platform="d3d9"` in `GamerProfile.xml` (locked read-only) |
| No keyboard/mouse | you're in exclusive fullscreen — use windowed + Alt+Enter or gamescope |
| Undo the mod | `fc2-apply-mods --restore` (mod-added files like `FarCry2MF.dll` are left in place) |
| Switched mod version | start a **new game** |

Vanilla backups: `~/.local/share/Steam/steamapps/common/Far Cry 2/.fc2-mod-backup/`.

## Notes

- **vkBasalt** does CAS sharpening only (the mod already de-oranges). Toggle in-game with `Home`.
  If it doesn't take effect, confirm the 32-bit layer loads under the Steam runtime.
- `fc2-apply-mods` is idempotent — re-running when files already match is a no-op.
- The GE-Proton path and MF-launcher exe-rename mean Steam won't track playtime normally.
