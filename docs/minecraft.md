# Minecraft on hydrogen — persistent server + couch split-screen

Four parts:

- **`modules/minecraft-server.nix`** — a Fabric server on hydrogen (the ZBook next to
  the projector), running as a system service. Always on, survives reboots, no login
  needed, backed up by borg. Carries the Vanilla Tweaks datapacks.
- **`packages/minecraft-client/`** — the game itself, pinned: client jar, 115
  libraries, 424 MiB of assets, the Fabric launch profile. Shared read-only by every
  client on the machine.
- **`modules/minecraft-couch.nix`** — one GNOME icon on hydrogen that opens a
  pre-launcher and then tiles up to four Minecraft clients on the projector, one
  gamepad each.
- **`packages/minecraft-client-mods.nix`** — the Fabric mod set, shared by the couch
  clients, sulfur's desktop client, and (the `server = true` subset) the server.

The design spec this was built from is `~/Downloads/specification.md`.

---

## Quick reference

| I want to… | Do this |
|---|---|
| Play on the couch | Click **Minecraft (Couch)** in the GNOME app grid |
| Play from sulfur | Click **Minecraft**, or run `minecraft-client` |
| Leave the game | `SUPER`+`SHIFT`+`Q` (returns to GNOME) |
| Get back to GNOME if something wedges | `sudo chvt 2`, or from another machine `ssh hydrogen 'sudo systemctl stop minecraft-couch'` |
| Add a player, or pair a controller | In the pre-launcher, before **Start playing** |
| Add or update a mod | Edit `packages/minecraft-client-mods.nix` and rebuild — the re-link is automatic on the next launch |
| Add or update a datapack | Regenerate the zips into `packages/minecraft-datapacks/`, rebuild, restart the server |
| See what mods are installed | `ls ~/.local/share/minecraft/<name>/mods/` |
| Move to a new Minecraft version | `packages/minecraft-client/update.sh <version>`, then re-pin the mods and the Fabric loader |
| Check what a new controller sends | `minecraft-couch-menu --probe` |
| See who is connected | `sudo journalctl -u minecraft-server -f` |
| Run a server command | `echo "time set day" \| sudo tee /run/minecraft-server.stdin` |
| Restart the server | `sudo systemctl restart minecraft-server` |
| Rebuild the archive by hand | `sudo systemctl restart minecraft-archive` |

---

## The offline guarantee

**There is no setup step, and nothing is downloaded at launch.** The game is a Nix
payload pinned by hash — `packages/minecraft-client/`, built from `libraries.json`,
which `update.sh` generates from Mojang's version manifest. `minecraft-client` hands
that read-only store path to [portablemc](https://github.com/mindstorm38/portablemc)
as its main directory and portablemc, finding every file already present at the right
size, downloads nothing.

Verified, and worth re-verifying after any bump — an empty game directory inside a
network namespace:

```console
$ unshare -rn minecraft-client --name LuckyObserver --game-dir /tmp/mc --offline -- --dry
[  OK  ] Loaded version fabric-loader-0.19.3-1.21.10
[  OK  ] Checked version jar
[  OK  ] Checked 4403 assets version 27
[  OK  ] Checked 78 class and 0 native libraries
```

Not one download, no Microsoft account, no instance to create. That is the whole
difference from the Prism setup this replaced (through 2026-08-05), where all of the
above was undeclared state fetched from Mojang on first launch and deliberately
*excluded* from the backups as "re-downloadable".

### The archive, and restoring from it

Pinning makes the client rebuildable from the flake — but only for as long as Mojang,
Modrinth and `maven.fabricmc.net` keep serving these exact versions. So hydrogen keeps
a copy: `minecraft-archive.service` mirrors the client and server closures into a
local Nix binary cache at `/var/lib/minecraft-archive` (~1.6 GB), and
`modules/backup.nix` sends that to both borg repos nightly. The unit has the store
paths baked into its `ExecStart`, so a switch that changes the payload re-runs it and
one that does not is a no-op.

To restore on a machine with the flake and no useful internet:

```console
$ nix copy --no-check-sigs --from file:///var/lib/minecraft-archive --all
$ nixos-rebuild switch --flake ~/nixos#sulfur
```

**Scope this honestly.** The archive guarantees *Minecraft* survives its upstreams
disappearing. It is not a full offline OS restore — everything else in the system
closure still comes from `cache.nixos.org`.

---

## Network and security model

The server runs `online-mode=false`. That is not optional — four children cannot
each have a Microsoft account attached to a shared launcher — but it means the
server performs **no identity verification at all**. Anything that can open a TCP
connection to 25565 may claim to be any username. A whitelist does not help,
because it matches on names that are themselves unauthenticated.

**Reachability is therefore the authentication boundary.**

- `openFirewall = false` on the service; 25565 is opened only on `br0`
  (`hosts/hydrogen.nix`).
- hydrogen has **no `wg0`**. The WireGuard hub lives on the router
  (`vpn.luckyobserver.com`, tunnel `10.40.0.0/24`) and remote peers route to
  hydrogen's LAN address `10.0.0.10` — so tunnel traffic arrives on `br0` exactly
  like LAN traffic. The single `br0` rule covers both.
- The router forwards only `51820/udp`, so 25565 is not reachable from the
  internet.

**Re-verify that last point after any router change.** From a phone on cellular:

```console
$ nc -vz <wan-address> 25565
nc: connect to <wan-address> port 25565 (tcp) failed: Connection refused
```

Residual risk, accepted: any enrolled peer can log in as any username. In practice
that means one child logging in as a sibling.

---

## Setup

### hydrogen (couch)

1. Pair the controllers. Nothing needs recording: click **Minecraft (Couch)**, choose
   **Pair a controller**, hold the pad's SYNC/PAIR button until its lights flash, and
   pick it out of the scan results. There is no chicken-and-egg problem with an
   unpaired first pad — every screen also accepts the keyboard (hydrogen has a wired
   Dell KB216), so you can reach the pairing screen with no controller at all.

   Confirm afterwards:

   ```console
   $ ls -l /dev/input/couchpad-*
   lrwxrwxrwx 1 root root 6 … /dev/input/couchpad-event19 -> event19
   ```

   One symlink per connected pad. It does not matter which is which — players say who
   they are at session start.

2. Play. Click **Minecraft (Couch)**, choose **Start playing**, and for each pad in
   turn the player holding it picks their name (or **Nobody (sit out)**, or **Start
   now** to skip the remaining pads). Expect roughly 30–60 s before everyone is in the
   world; the launcher staggers them and places each window as it appears.

3. Once, per child, in-game: press `F3`+`P` until it says *"pauseOnLostFocus: false"*
   so background windows keep rendering, and set render distance to 8. This lands in
   that player's `options.txt` and is backed up.

### sulfur (desktop)

Click **Minecraft**, or run `minecraft-client`. It connects to `10.0.0.10:25565` as
`LuckyObserver` (`services.minecraftClient` in `hosts/sulfur.nix`). Nothing to
install, nothing to configure.

Note the one-login-per-username rule: if sheath is playing `LuckyObserver` from
sulfur, the couch cannot also be `LuckyObserver`.

### Migrating from Prism (one-time, 2026-08-05)

Worlds are server-side and untouched. What is worth carrying over is each player's
video settings and mod configuration:

```console
# hydrogen, per player
$ cp -n ~/.local/share/minecraft-couch/$NAME/instances/couch/minecraft/options.txt \
        ~/.local/share/minecraft-couch/$NAME/
$ cp -rn ~/.local/share/minecraft-couch/$NAME/instances/couch/minecraft/config/. \
         ~/.local/share/minecraft-couch/$NAME/config/

# sulfur
$ mkdir -p ~/.local/share/minecraft/LuckyObserver
$ cp -n ~/.local/share/PrismLauncher/instances/Hydrogen/minecraft/{options.txt,servers.dat} \
        ~/.local/share/minecraft/LuckyObserver/
```

Leave the old Prism trees alone until the new setup has been played a few times, then
remove `~/.local/share/PrismLauncher` and the per-player `instances/` subdirectories.

---

## Players

The roster lives in `~/.local/share/minecraft-couch/players.json` and is managed
from the pre-launcher — **Add a player** and **Remove a player**. It is seeded on
first run from `seedPlayers` in `modules/minecraft-couch.nix`.

> **Editing `seedPlayers` later does nothing.** Once the JSON exists it is
> authoritative. To re-seed from Nix, delete the file. This is the price of a
> roster you can change from the couch without a rebuild.

> **The names are load-bearing in one direction.** An offline UUID is a hash of
> the username, so *renaming* a player after they have played orphans that
> character's inventory, advancements and ender chest. *Removing* and re-adding
> the identical name is safe and returns the same character — the roster is only
> a list of names, and the server keeps the characters.

Names must be 3–16 characters of `[A-Za-z0-9_]`. The 16-character cap is not a
style rule: Minecraft enforces it on the wire, and an over-long name fails to
encode its login packet, so the client cannot connect at all. The pre-launcher
rejects bad names as you type, `minecraft-client` rejects them at launch, and a Nix
assertion catches a bad seed at build time.

`LuckyObserver` is seeded alongside the kids so sheath can play from the couch as
well as from sulfur — though not from both at once.

Each player gets a game directory of their own — `~/.local/share/minecraft-couch/<name>`
on hydrogen, `~/.local/share/minecraft/<name>` elsewhere — holding only their
`options.txt`, `config/`, `screenshots/` and a `mods` symlink. The game itself is one
shared store path, so a fifth player costs kilobytes.

`minecraft-client` computes the offline UUID exactly as the game does —
`UUID.nameUUIDFromBytes("OfflinePlayer:<name>")`, an MD5 with the version and variant
bits forced. portablemc's own offline session would invent one from a private
namespace instead. It makes no difference to the server, which derives the UUID from
the name it is given, but it keeps client-side identity consistent.

---

## Mods and datapacks

Two different mechanisms, and the difference matters:

| | Where it runs | Where it lives | Who has to install it |
|---|---|---|---|
| **Mods** | Fabric, client **and** the `server = true` subset | `packages/minecraft-client-mods.nix` | Nix, everywhere |
| **Datapacks** | the server, vanilla | `packages/minecraft-datapacks/` | nobody — the server pushes them |

**The server runs Fabric** (since 2026-08-04, `packages/fabric-server.nix`). It did
not until then, and the reason it does now is the reason two features were previously
impossible: since 1.21.2 the recipe list and container contents live server-side and
are not sent to clients, so no client-only mod can reach them.

**The unmodded-join guarantee still holds** and is the thing to re-verify after any
change to the `server = true` set: a phone, laptop or tablet must still join over the
tunnel with nothing installed. It holds because none of the server mods add registry
entries, so Fabric API's registry sync has nothing to reject a vanilla client over.
Test it, do not assume it.

### The mod set

| Mod | What it is for | On the server too |
|---|---|---|
| Sodium | the renderer — the reason four clients on one GPU are comfortable | |
| Controlify | gamepad support and controller-driven menus | |
| Xaero's Minimap | minimap and waypoints | |
| Better Name Visibility | legible nameplates at quarter-screen | |
| Jade | what am I looking at | |
| Nearby Crafting | chest contents count as your inventory when crafting | ✓ |
| JEI | recipe viewer | ✓ |
| Fabric API, YACL, Mod Menu, Recipe Book Access API | dependencies of the above | ✓ |

Nearby Crafting replaced Effortless Crafting, which was the client-only approximation
used while the server was vanilla: it had to physically open each chest over the
network behind a held Ctrl — a key Controlify has no equivalent for, so on a gamepad
the feature was unreachable. JEI is likewise only useful now that it is on the server;
client-only, it printed *"JEI is missing recipes"* in chat on every join, which is why
it was installed, removed, and installed again.

EMI is still the nicer viewer but stopped at 1.21.1. REI's local fallback is broken by
our own Unlock All Recipes datapack ([#2063](https://github.com/shedaniel/RoughlyEnoughItems/issues/2063));
the fix merged 2026-07-29 and is still unreleased. Neither matters now that JEI can ask
the server.

Default configs live in `configDefaults` in `packages/minecraft-client-mods.nix` and
are seeded **once** into each game directory's `config/`; anything changed in Mod Menu
afterwards is kept. The set is currently empty — Nearby Crafting's defaults need no
adjustment.

To add or update a mod: find the version on Modrinth for `loader=fabric,
game_version=1.21.10`, add an entry to `packages/minecraft-client-mods.nix` (the header
has the API query and the hash-conversion one-liner), and rebuild. There is no re-link
step — `minecraft-client` re-points `mods/` at the current store path on every launch,
on both machines.

> **Nothing can install a mod into `mods/` at runtime** — it is a read-only store
> path. That is the trade for one list driving three places. Add mods in Nix instead.
> A pre-existing non-empty `mods/` directory is stashed as `mods.stateful` rather than
> deleted.

Assertions in `modules/minecraft-client.nix` tie the pinned mod `mcVersion` to both
`pkgs.minecraft-server.version` and the client payload, so a nixpkgs bump that moves
the server off 1.21.10 fails the build instead of showing four children an
incompatible-mod screen.

### Datapacks

Four Vanilla Tweaks packs: **CoordinatesHUD** (XYZ and a clock in the actionbar),
**Unlock All Recipes**, **Graves** (death drops go in a grave block) and
**Multiplayer Sleep** (night skips without everyone asleep; `/trigger mpSleep` for
settings).

`minecraft-server.nix`'s `preStart` deletes `world/datapacks/vt-*.zip` and re-copies
the current set on every start, so dropping a pack from Nix removes it from the world
too. The `vt-` prefix bounds what Nix will delete — a datapack you drop in by hand is
never touched. Vanilla auto-enables packs it finds at world load, so a restart is all
it takes.

Two non-obvious constraints, both learned the hard way and worth not re-deriving:

- **The zips are vendored in the repo, not fetched.** vanillatweaks.net builds a
  bundle per request and hands back a single-use URL — POSTing the identical
  selection twice returns two different links. There is nothing stable for `fetchurl`
  to pin, and a link that 404s later would break the nightly auto-update.
  The regeneration `curl` is in the header of `packages/minecraft-datapacks.nix`.
- **They are copied into the world, not symlinked.** Since 1.19.4 Minecraft refuses
  to follow symlinks inside a world directory unless they are listed in
  `allowed_symlinks.txt`, so the obvious `systemd.tmpfiles` `L+` rule yields a world
  with silently zero datapacks.

Every pack declares `supported_formats` 48–94, i.e. MC 1.21 through 1.21.11. Nothing
in Nix checks this; a server past 1.21.11 will just log them as incompatible and skip
them, so regenerate at the next major version bump.

---

## Moving to a new Minecraft version

Five things have to agree, and the nightly auto-update moves the first without asking.
In order:

1. `nixpkgs`' `minecraft-server` — the server jar. This is what moves on its own.
2. `packages/minecraft-client/update.sh <version>` — regenerates `libraries.json`.
   Rebuild once; the assets fixed-output derivation will fail with the new hash, which
   goes into `assetObjects.outputHash` in `packages/minecraft-client/default.nix`.
3. `packages/fabric-server.nix` — `mcVersion`, the `intermediary` hash, and the loader
   version if it moved. Re-transcribe from
   `https://meta.fabricmc.net/v2/versions/loader/<mc>/<loader>/server/json`. This also
   feeds the client's Fabric profile, so it is one edit for both sides.
4. `packages/minecraft-client-mods.nix` — re-pin every jar, then bump `mcVersion`.
   Check upstream support first; not every mod tracks a point release promptly.
5. The datapacks' `supported_formats` window (server log only, cannot be checked in
   Nix).

The assertions catch 1 vs 2 vs 3 vs 4 at eval. Nothing catches 5.

---

## How the launcher works

```
.desktop icon
  └─ minecraft-couch                      runs inside the GNOME session
      └─ systemd  minecraft-couch         a REAL logind session on tty7
          └─ Hyprland (generated config)  tiles; no bars, idle or lock
              └─ minecraft-couch-spawn    places N windows by hyprctl address
                  ├─ minecraft-couch-menu the pre-launcher, in a fullscreen foot
                  └─ minecraft-couch-player <name> <event node>
                      └─ bwrap: tmpfs over /dev/input, one pad bound back
                          └─ minecraft-client --name <name> --game-dir …/<name>
                                             --server 127.0.0.1:25565
                              └─ portablemc --main-dir /nix/store/…-minecraft-client-1.21.10
                                            --work-dir …/<name>
                                  └─ java -cp … KnotClient

per player, all that is on disk:
  ~/.local/share/minecraft-couch/<name>/
    options.txt  config/  screenshots/  mods -> /nix/store/…-minecraft-client-mods-1.21.10
```

Five decisions worth knowing when debugging:

**The game is one shared read-only store path.** Every client points `--main-dir` at
it; only `--work-dir` is per player. Under Prism this was four data directories with
seven symlinked trees each, fanned out by a `minecraft-couch-sync` command that had to
be re-run after every mod change — all of which existed because Prism refuses to run
twice from one data directory (its single-instance lock is keyed on that path) and a
second `--launch` would have spawned the game outside the second sandbox, moving every
character in unison. A CLI launcher is just a process, so none of that machinery
survives.

**Identity is asked, not wired.** This used to key each seat to a controller's
Bluetooth MAC in a udev rule, which made identity a property of the *hardware*:
pick up a sibling's pad and you were your sibling, "2 players" always meant seats
1 and 2 (so the third and fourth child's pads did nothing), and four MACs had to
be collected by hand before anything worked. Now one generic udev rule symlinks
every joystick node, and the pre-launcher asks who is holding each pad. The
question the MAC answered — *which node is seat N's?* — is simply never asked.

The pre-launcher takes gamepad **and** keyboard input on every screen, and needs
only two gamepad actions: move and confirm. There is deliberately no "back"
button — every screen carries a `Back` entry instead. That matters because the
three Switch Pro pads (`hid-nintendo`) and the Xbox Elite (`xpadneo`) disagree on
how a D-pad is reported: it can arrive as a hat axis (`ABS_HAT0X/Y`) or as
discrete buttons (`BTN_DPAD_*`). Rather than guess, all of those move the cursor,
and any *other* button confirms. `minecraft-couch-menu --probe` dumps raw events
from a pad if you ever need to check what a new controller actually sends.

**A separate VT, not a nested compositor.** GNOME has to keep running — RustDesk's
screen capture depends on that session, and it is the only remote desktop that
works on this box. But Mutter cannot tile into quadrants, cannot let a client
position itself, and cannot fullscreen a nested compositor's window. Running
Hyprland as its own logind session on tty7 sidesteps all three: switching VTs
makes GNOME inactive, it drops DRM master, and Hyprland drives the GPU natively.
`PAMName=login` + `TTYPath=` in the unit is what makes logind register a real
session — without that pair, Hyprland cannot take DRM master at all.

**Explicit window placement, not the tiler.** Hyprland's `dwindle` splits whichever
window has focus, which for four clients gives "left half plus three stacked on
the right", not quadrants. `minecraft-couch-spawn` waits for each window to map
and positions it by address instead — deterministic regardless of which JVM
finishes starting first, and it makes the 1/2/3-player layouts fall out of the
same code. Geometry comes from `hyprctl monitors`, so there is no 1080p
assumption baked in.

**bubblewrap for input.** Gamepad input is read straight from `/dev/input` via
evdev and never touches the display server, so by default every client sees every
pad and all four characters move in unison. Each client therefore runs with a
tmpfs over `/dev/input` and only its own player's event node bound back in. Note
the wrapper binds the *resolved* node (`event19`), not the `couchpad-*` symlink —
SDL enumerates `/dev/input/event*`, so a sandbox holding only the symlink would
show the game no gamepad at all.

---

## Rendering path

Clients run under **XWayland**, which needs no configuration and whose usual complaint
(HiDPI blurriness) is irrelevant at 1080p. Verified working on sulfur's NVIDIA +
Wayland session, which is the pairing that has broken other things on these machines.

To try native Wayland instead, pass the JVM argument through the launcher:

```console
$ minecraft-client -- --jvm-args '-Dorg.lwjgl.glfw.libname=/run/current-system/sw/lib/libglfw.so'
```

…pointing at `pkgs.glfw3-minecraft` (add it to `environment.systemPackages` first;
note the old `glfw-wayland-minecraft` name is a removed alias). The known catch is
that the mouse cursor does not re-center when opening inventory screens — but all
four players navigate menus via Controlify, so that path may never be exercised.
Check before bothering to patch anything.

Scheduled cleanup: Minecraft 26.3 replaced GLFW with SDL3 and gained native
Wayland support. Once that reaches a stable release with mod ecosystem support,
this whole section goes away.

---

## Backups

`/var/lib/minecraft` is in `backupPaths` in `modules/backup.nix`, so it goes to
both the local repo (`/data/borg`) and BorgBase nightly at 03:00. That covers the
world, `playerdata/`, `ops.json` and `server.properties` — everything needed to
bring the server back.

Two more paths, for different reasons:

```
/var/lib/minecraft-archive          the game itself (see "The offline guarantee")
~/.local/share/minecraft-couch      roster + each player's settings
```

Nobody loses a character or a build if the couch directory goes — the world is
server-side. What it holds is what the flake *cannot* rebuild: `players.json`
(authoritative once created, so anyone added from the couch exists only there) and
each child's `options.txt` and Controlify bindings. It is kilobytes per player.

> **The couch directory is pre-created by `systemd.tmpfiles`, deliberately.** The borg
> jobs run with `failOnWarnings = true`, and borg treats a missing source path as a
> warning and exits 1 — so on a machine where nobody had played yet, adding the path
> would have failed the *entire* nightly backup, Nextcloud and Immich included. Do not
> remove the tmpfiles rule without also removing the path.

Because the server writes region files continuously, both jobs flush first:
`preHook` sends `save-off` then `save-all flush` through the server console FIFO
at `/run/minecraft-server.stdin`, waits 5 s, and archives. `save-on` runs from
`ExecStopPost` rather than `postHook` on purpose — `postHook` is skipped when borg
exits non-zero, which would leave autosave off until the next server restart.

Verify a restore at least once:

```console
$ sudo borg-local backup
$ sudo borg-local list ::<archive> | grep 'minecraft/world/region' | head
$ sudo borg-local extract --strip-components 3 ::<archive> var/lib/minecraft/world/level.dat
```

Keep exactly one canonical world, on the server. Do not keep a local copy "as a
backup" — two worlds drift and there will be an argument about which one has the
base in it.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Icon does nothing, notification says the server is not running | `sudo systemctl status minecraft-server`; check `journalctl -u minecraft-server` |
| "No controllers are connected" | Pad is asleep or unpaired. Wake it, or use **Pair a controller**; `ls -l /dev/input/couchpad-*` to confirm |
| A player is missing from the list | Add them with **Add a player** — the roster is `~/.local/share/minecraft-couch/players.json`, not Nix |
| Launch fails: "Checking libraries… FAILED" or a download attempt | The payload is incomplete — a packaging bug, not a runtime one. Rebuild; if it persists, re-run `packages/minecraft-client/update.sh` |
| Launch fails: read-only file system under `/nix/store` | Same cause. portablemc decided something was missing and tried to fetch it into the payload |
| Pad cannot move the cursor in the pre-launcher | Its D-pad reports codes not in the accepted set. `minecraft-couch-menu --probe`, press the D-pad, and widen the list in `modules/minecraft-couch.nix`. The left stick and the keyboard both work meanwhile |
| Projector goes black and stays there | DRM master handoff failed. `sudo chvt 2` to return to GNOME; `journalctl -u minecraft-couch` for the Hyprland log |
| All characters move together | The bwrap isolation is not taking. Check the nodes handed to each `minecraft-couch-player` are distinct — `ls -l /dev/input/couchpad-*` should show one symlink per pad, each resolving to a different `eventN` |
| Only one window, or windows stacked | `minecraft-couch-spawn` could not match the window class. `hyprctl clients` during a session and check the class really contains "minecraft" |
| Client can't join: "Chat disabled due to missing profile public key" | `enforce-secure-profile` drifted back to true — it must be `false` alongside `online-mode=false` |
| A mod is missing after a rebuild | Launch again — the re-link happens at launch, and the message `minecraft-client: mods -> /nix/store/…` says it took |
| `minecraft-client` refuses: "nowhere safe to stash it" | Both `mods/` and `mods.stateful` hold real files. Merge or delete one by hand |
| Datapacks not in effect | `echo "datapack list" \| sudo tee /run/minecraft-server.stdin`, then check the journal. If they are listed as incompatible, the server moved past 1.21.11 — regenerate the zips |
| Nightly backup fails on a missing path | `/var/lib/minecraft-archive` should exist after the first switch — `systemctl status minecraft-archive` |
| Session exits but GNOME doesn't come back | `sudo chvt 2`. `ExecStopPost` should do this automatically; check `/run/minecraft-couch.prev-vt` was written |

### Fallback if the VT handoff proves unreliable

This is the one part of the design that could not be validated before writing it,
and this box has a history here — gnome-remote-desktop RDP and Sunshine's KMS
capture both failed on this exact GPU/compositor pairing and were removed.

If Hyprland cannot reliably take DRM master from Mutter, run it nested inside the
GNOME session instead, using gamescope purely as the fullscreen shell (Hyprland
cannot request fullscreen for itself; gamescope can):

```
exec gamescope -f -W 1920 -H 1080 -- Hyprland --config <conf>
```

That is a change to `minecraft-couch-session` and the unit only — the udev rule,
pre-launcher, bubblewrap wrapper, window placement and desktop entry are all
unaffected. It costs one extra compositing pass.

---

## Known limitations

- **No GUI launcher.** Adding a singleplayer world, a different Minecraft version or
  a modpack means editing Nix and rebuilding. That is the accepted trade for a client
  that is fully declared and restorable; Prism was removed on 2026-08-05.
- **No late join.** Whoever is not at the pre-launcher when you press *Start now*
  is not in that session; a kid arriving later needs the session restarted.
  Re-tiling live windows and spawning into an existing layout is a much larger
  change than it looks, and was deliberately not attempted.
- **One login per username.** If sheath is playing `LuckyObserver` from sulfur,
  the couch cannot also be `LuckyObserver` — the server rejects the duplicate.
- **Everyone is Steve or Alex.** Offline mode cannot fetch skins, so four kids on one
  screen look identical. Better Name Visibility (in the mod set) answers the half of
  this that actually matters — telling each other apart at quarter-screen — by making
  nameplates legible. The skins themselves would need a separate mod; nobody has
  asked yet.
- **No terrain pre-generation.** Vanilla has no pregen command, and the spec rates
  it polish rather than a requirement on this hardware. If concurrent exploration
  stutters, lowering Sodium's chunk-build thread count per client is the first
  lever to try; do not preemptively cap it.
- **Pascal is end-of-life.** `hardware.nvidia.package` is pinned to the
  `production` (580) branch in `hosts/hydrogen.nix`. Every branch in the current
  nixpkgs pin happens to be 580.142, so the pin is a no-op today — its job is to
  stop the nightly auto-update from moving the GPU onto a 590 branch that does not
  support this card. Revisit deliberately at the next NixOS release bump.
