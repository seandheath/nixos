# Minecraft on hydrogen — persistent server + couch split-screen

- **`modules/minecraft-server.nix`** — Fabric server on hydrogen, system service, always on,
  backed up by borg. Carries the Vanilla Tweaks datapacks.
- **`packages/minecraft-client/`** — the pinned game: client jar, 115 libraries, 424 MiB of
  assets, the Fabric launch profile. Shared read-only by every client on the machine.
- **`modules/minecraft-couch.nix`** — one GNOME icon that opens a pre-launcher and tiles up to
  four clients on the projector, one gamepad each.
- **`packages/minecraft-client-mods.nix`** — the mod set, shared by the couch clients, sulfur's
  client, and (the `server = true` subset) the server.
- **`packages/minecraft-launcher.nix`** — the pre-launcher everywhere else: pick a player, pick
  a world, start it, play. See *Choosing a world*.
- **`packages/minecraft-server-image.nix`** / **`minecraft-server-ctl.nix`** — on-demand worlds
  as rootless podman containers, built from the same pinned server as the always-on one.
- **`packages/minecraft-menu/`** — the menu widgets both pre-launchers draw with.

## Quick reference

| I want to… | Do this |
|---|---|
| Play on the couch | Click **Minecraft (Couch)** in the GNOME app grid |
| Play from sulfur | Click **Minecraft**, or run `minecraft-client` |
| Choose a player and a world | Click **Minecraft (choose a world)**, or run `minecraft-launcher` |
| Make a new world | In the launcher: *Create a new world* → shared, or only this computer |
| See the on-demand worlds | `minecraft-server-ctl list` |
| Stop one | `minecraft-server-ctl stop <name>` |
| Leave the game | `SUPER`+`SHIFT`+`Q` |
| Unwedge the projector | `sudo chvt 2`, or `ssh hydrogen 'sudo systemctl stop minecraft-couch'` |
| Add a player, pair a controller | In the pre-launcher, before **Start playing** |
| Add or update a mod | Edit `packages/minecraft-client-mods.nix`, rebuild. Re-link is automatic at next launch |
| Add or update a datapack | Regenerate zips into `packages/minecraft-datapacks/`, rebuild, restart the server |
| See installed mods | `ls ~/.local/share/minecraft/<name>/mods/` |
| New Minecraft version | `packages/minecraft-client/update.sh <version>`, then re-pin mods and Fabric loader |
| Check what a controller sends | `minecraft-couch-menu --probe` |
| See who is connected | `sudo journalctl -u minecraft-server -f` |
| Run a server command | `echo "time set day" \| sudo tee /run/minecraft-server.stdin` |
| Restart the server | `sudo systemctl restart minecraft-server` |
| Rebuild the archive | `sudo systemctl restart minecraft-archive` |

## Offline guarantee

No setup step, nothing downloaded at launch. `minecraft-client` hands portablemc the
read-only store path as `--main-dir`; every file is already present at the right size, so it
downloads nothing. `--fetch-exclude-all` stops the version-metadata re-validation going out.

Re-verify after any bump, in a network namespace:

```console
$ unshare -rn minecraft-client --name LuckyObserver --game-dir /tmp/mc --offline -- --dry
```

Expect: both versions loaded, 78 libraries, 4403 assets, JVM 21, exit 0.

### The archive

Pinning only works while Mojang, Modrinth and `maven.fabricmc.net` keep serving these exact
versions, so `minecraft-archive.service` mirrors the client and server closures into a local
binary cache at `/var/lib/minecraft-archive` (~1.6 GB), which `modules/backup.nix` sends to
all three borg repos. Restore on a machine with the flake and no useful internet:

```console
$ nix copy --no-check-sigs --from file:///var/lib/minecraft-archive --all
$ nixos-rebuild switch --flake ~/nixos#sulfur
```

This covers *Minecraft* only — the rest of the system closure still comes from
`cache.nixos.org`.

## Network and security model

The server runs `online-mode=false` — four children cannot each hold a Microsoft account — so
it performs **no identity verification**. Anything that reaches 25565 may claim to be any
username, and a whitelist matches on names that are themselves unauthenticated.
**Reachability is the authentication boundary.**

- `openFirewall = false`; tagged family clients reach hydrogen's `tag:server` identity on
  the declared Minecraft ports. Couch clients connect over 127.0.0.1.
- Headscale policy, rather than a public port forward, controls reachability.

Re-verify after any router or ACL change. From a device outside the tailnet:

```console
$ nc -vz <wan-address> 25565     # must fail
$ nc -vz 100.64.0.3 25565         # must fail
```

Residual risk, accepted: any enrolled peer can log in as any username — in practice, one child
logging in as a sibling.

## Setup

**hydrogen.** Pair controllers from the pre-launcher (**Pair a controller**); every screen also
accepts the keyboard, so there is no chicken-and-egg with an unpaired first pad. Confirm with
`ls -l /dev/input/couchpad-*` — one symlink per pad, order irrelevant. Then **Start playing**
and each player picks their name. Expect 30–60 s for everyone to be in the world.

Once per child, in-game: `F3`+`P` until it says *pauseOnLostFocus: false* so background windows
keep rendering, and set render distance to 8.

**sulfur.** Click **Minecraft** or run `minecraft-client`. Connects to
`mc.luckyobserver.com:25565` as `LuckyObserver` (`services.minecraftClient` in
`hosts/sulfur.nix`).

## Players

The roster is `~/.local/share/minecraft-couch/players.json`, managed from the pre-launcher and
seeded once from `seedPlayers` in `modules/minecraft-couch.nix`.

- **Editing `seedPlayers` later does nothing** — once the JSON exists it is authoritative.
  Delete the file to re-seed. That is the price of a roster changeable without a rebuild.
- **Renaming orphans a character.** An offline UUID is a hash of the username, so a rename
  loses that character's inventory, advancements and ender chest. Removing and re-adding the
  identical name is safe.
- Names must be 3–16 chars of `[A-Za-z0-9_]`. The cap is enforced on the wire — an over-long
  name fails to encode its login packet and cannot connect at all.
- One login per username: sheath cannot be `LuckyObserver` on sulfur and the couch at once.

Each player gets a game directory holding only `options.txt`, `config/`, `screenshots/` and a
`mods` symlink; the game is one shared store path, so a fifth player costs kilobytes.

## Choosing a world

Everything except the couch runs `minecraft-launcher` first: pick who is playing, pick
which world, and it starts the world before starting the game. The plain **Minecraft**
icon still quick-plays straight into the family server and is the faster way there. New
worlds default to hydrogen and are shared; local-only is an explicit second choice.

Every laptop has a dedicated `minecraft-control-<host>` private key encrypted in its SOPS
file and materialized mode 0400 for its player. Hydrogen authorizes only the public half,
behind the forced `minecraft-server-ctl-ssh` command, so the key grants no shell. The
launcher asks hydrogen for `minecraft-server-ctl worlds` on startup; persistent world
directories are authoritative, so all laptops see stopped worlds and worlds created by
another player. If hydrogen is temporarily unreachable, the last cached list and local
worlds remain usable.

A world is one of three things:

| Where | What it is | Reachable by |
|---|---|---|
| on this machine | a rootless podman container here | only this machine, on 127.0.0.1 |
| on hydrogen | a container on hydrogen, alongside the shared world | anyone on the family tunnel |
| elsewhere | just an address to join; nothing is managed | whoever can already reach it |

The first two are created on first play, not when you add them, so adding a world costs
nothing until someone wants it. First start generates terrain and takes a minute or two;
the launcher shows a timer rather than freezing.

Worlds live in `~/.local/share/minecraft/servers/<name>/` locally, and in
`/var/lib/minecraft-servers/<name>/` on hydrogen where the nightly borg run picks them up.
Removing a world in the launcher removes the container and keeps the directory, so the same
name brings the world back.

Ports come out of 25566-25575, opened as a range on both tunnels. That range is the limit
on how many worlds can exist at once, because a container on a port outside it would be
unreachable until the next rebuild.

`minecraft-server-ctl` is the same thing without the menu: `list`, `create`, `start`,
`stop`, `logs`, `remove`. hydrogen exposes exactly that over SSH behind a forced command,
so a control key grants no shell.

### Versions

Every world runs the fleet pin from `packages/minecraft-version.nix`, built from the same
`packages/fabric-server.nix` as the shared world, with the same mods and datapacks. That is
deliberate: a container running a different build than the client payload would fail the
assertions, or worse, not fail them.

## Mods and datapacks

| | Runs on | Lives in | Installed by |
|---|---|---|---|
| **Mods** | Fabric, client + the `server = true` subset | `packages/minecraft-client-mods.nix` | Nix, everywhere |
| **Datapacks** | server, vanilla | `packages/minecraft-datapacks/` | nobody — the server pushes them |

**The server runs Fabric** (`packages/fabric-server.nix`). Since 1.21.2 the recipe list and
container contents are server-side and not sent to clients, so no client-only mod can reach
them — that is why JEI and Nearby Crafting need a modded server.

**The unmodded-join guarantee holds** and is the thing to re-verify after any change to the
`server = true` set: a phone or tablet must still join over the tunnel with nothing installed.
It holds because no server mod adds registry entries, so Fabric API's registry sync has
nothing to reject a vanilla client over. Test it, do not assume it.

| Mod | For | Server too |
|---|---|---|
| Sodium | the renderer — why four clients on one GPU are comfortable | |
| Controlify | gamepad support and controller-driven menus | |
| Xaero's Minimap | minimap and waypoints | |
| Better Name Visibility | legible nameplates at quarter-screen | |
| Jade | what am I looking at | |
| Nearby Crafting | chest contents count as inventory when crafting | ✓ |
| JEI | recipe viewer | ✓ |
| Fabric API, YACL, Mod Menu, Recipe Book Access API | dependencies | ✓ |

To add or update a mod: find the version on Modrinth for `loader=fabric,
game_version=1.21.10`, add an entry (the file header has the API query and hash one-liner),
rebuild. `minecraft-client` re-points `mods/` at the current store path every launch.

> **Nothing can install a mod at runtime** — `mods/` is a read-only store path. A pre-existing
> non-empty `mods/` is stashed as `mods.stateful` rather than deleted.

Assertions in `modules/minecraft-client.nix` tie the mod `mcVersion` to both
`pkgs.minecraft-server.version` and the client payload, so a nixpkgs bump off 1.21.10 fails
the build instead of showing four children an incompatible-mod screen.

### Datapacks

Four Vanilla Tweaks packs: CoordinatesHUD, Unlock All Recipes, Graves, Multiplayer Sleep
(`/trigger mpSleep` for settings).

`preStart` deletes `world/datapacks/vt-*.zip` and re-copies the current set every start, so
dropping a pack from Nix removes it from the world. The `vt-` prefix bounds what Nix deletes —
a hand-dropped datapack is never touched.

- **Zips are vendored, not fetched.** vanillatweaks.net builds a bundle per request and hands
  back a single-use URL; there is nothing stable to pin. Regeneration `curl` is in the header
  of `packages/minecraft-datapacks.nix`.
- **Copied, not symlinked.** Since 1.19.4 Minecraft refuses symlinks inside a world directory
  unless listed in `allowed_symlinks.txt`, so a `systemd.tmpfiles` `L+` rule yields a world
  with silently zero datapacks.

Packs declare `supported_formats` 48–94 (MC 1.21–1.21.11). Nothing in Nix checks this;
regenerate at the next major bump.

## Moving to a new Minecraft version

Five things must agree, and the nightly moves the first without asking:

1. `nixpkgs`' `minecraft-server` — the server jar.
2. `packages/minecraft-client/update.sh <version>` — regenerates `libraries.json`. Rebuild
   once; the assets FOD fails with the new hash, which goes into `assetObjects.outputHash`.
3. `packages/fabric-server.nix` — `mcVersion`, the `intermediary` hash, loader version if
   moved. Re-transcribe from
   `https://meta.fabricmc.net/v2/versions/loader/<mc>/<loader>/server/json`. Feeds both sides.
4. `packages/minecraft-client-mods.nix` — re-pin every jar, then bump `mcVersion`. Not every
   mod tracks a point release promptly.
5. The datapacks' `supported_formats` window (server log only).

Assertions catch 1–4 at eval. Nothing catches 5.

## How the launcher works

```
.desktop icon
  └─ minecraft-couch                      runs inside the GNOME session
      └─ systemd  minecraft-couch         a real logind session on tty7
          └─ Hyprland (generated config)  tiles; no bars, idle or lock
              └─ minecraft-couch-spawn    places N windows by hyprctl address
                  ├─ minecraft-couch-menu the pre-launcher
                  └─ minecraft-couch-player <name> <event node>
                      └─ bwrap: tmpfs over /dev/input, one pad bound back
                          └─ minecraft-client --name … --game-dir … -s 127.0.0.1
```

Four things worth knowing when debugging:

- **One shared read-only payload.** `--mc-dir` and `--bin-dir` must both be stated — portablemc
  5.x defaults `--mc-dir` to `--main-dir` and `--bin-dir` to `<main-dir>/bin` regardless, so
  omitting either aims a write at the store.
- **Identity is asked, not wired.** One generic udev rule symlinks every joystick node and the
  pre-launcher asks who holds each pad. Every screen takes gamepad and keyboard; there is no
  "back" button because the Switch Pro pads (`hid-nintendo`) and the Xbox Elite (`xpadneo`)
  disagree on whether a D-pad is a hat axis or discrete buttons, so all of those move the
  cursor and any other button confirms.
- **A separate VT, not a nested compositor.** GNOME must keep running for RustDesk capture, but
  Mutter cannot tile into quadrants, let a client position itself, or fullscreen a nested
  compositor. `PAMName=login` + `TTYPath=` is what makes logind register a real session —
  without that pair Hyprland cannot take DRM master.
- **bubblewrap for input.** evdev bypasses the display server, so by default every client sees
  every pad and all four characters move in unison. Each client gets a tmpfs over `/dev/input`
  with only its own node bound back — the *resolved* node (`event19`), not the `couchpad-*`
  symlink, because SDL enumerates `/dev/input/event*`.

Clients run under XWayland. Minecraft 26.3 replaces GLFW with SDL3 and gains native Wayland;
revisit then.

## Backups

`/var/lib/minecraft` is in `backupPaths` (`modules/backup.nix`) — world, `playerdata/`,
`ops.json`, `server.properties`. Two more paths:

- `/var/lib/minecraft-archive` — the game itself, see above.
- `~/.local/share/minecraft-couch` — roster plus each player's settings. Kilobytes, and the
  only part the flake cannot rebuild: `players.json` is authoritative once created.

> **The couch directory is pre-created by `systemd.tmpfiles` deliberately.** The borg jobs run
> `failOnWarnings = true` and borg treats a missing source as a warning, so on a machine where
> nobody had played this would have failed the *entire* nightly backup, Nextcloud and Immich
> included. Do not remove the tmpfiles rule without also removing the path.

`borg-cmd backup` and the 03:00 fleet job refresh PostgreSQL dumps, then checkpoint
Minecraft before backing up to `/data/borg` and BorgBase. The shared runner restores
autosaving with an exit trap, including when a repository fails.

Verify a restore at least once:

```console
$ sudo borg-cmd backup --data --remote
$ sudo borg-cmd data list ::<archive> | grep 'minecraft/world/region' | head
$ sudo borg-cmd data extract --strip-components 3 ::<archive> var/lib/minecraft/world/level.dat
```

Keep exactly one canonical world, on the server.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Icon does nothing, "server not running" | `systemctl status minecraft-server`; check its journal |
| "No controllers are connected" | Pad asleep or unpaired. Wake it or use **Pair a controller**; confirm with `ls -l /dev/input/couchpad-*` |
| A player is missing from the list | Add them with **Add a player** — the roster is `players.json`, not Nix |
| Launch fails: "Checking libraries… FAILED", or a download attempt | Incomplete payload — a packaging bug. Rebuild; if it persists re-run `update.sh` |
| Launch fails: read-only fs under `/nix/store` | Payload incomplete, or `--mc-dir`/`--bin-dir` missing from the launcher |
| Pad cannot move the pre-launcher cursor | D-pad codes not in the accepted set. `minecraft-couch-menu --probe`, widen the list. Left stick and keyboard work meanwhile |
| Projector black and stays there | DRM master handoff failed. `sudo chvt 2`; `journalctl -u minecraft-couch` |
| All characters move together | bwrap isolation not taking. Each `minecraft-couch-player` must get a distinct `eventN` |
| One window, or windows stacked | `minecraft-couch-spawn` could not match the window class. Check `hyprctl clients` |
| "Chat disabled due to missing profile public key" | `enforce-secure-profile` drifted true — must be false alongside `online-mode=false` |
| A mod is missing after a rebuild | Launch again; the re-link happens at launch and logs `mods -> /nix/store/…` |
| "nowhere safe to stash it" | Both `mods/` and `mods.stateful` hold real files. Merge or delete one by hand |
| Datapacks not in effect | `echo "datapack list" \| sudo tee /run/minecraft-server.stdin`. Listed incompatible means the server moved past 1.21.11 |
| Session exits but GNOME doesn't return | `sudo chvt 2`. `ExecStopPost` should do this; check `/run/minecraft-couch.prev-vt` |

If the VT handoff proves unreliable, run Hyprland nested inside GNOME with gamescope as the
fullscreen shell (`exec gamescope -f -W 1920 -H 1080 -- Hyprland --config <conf>`). That is a
change to `minecraft-couch-session` and the unit only, at the cost of one compositing pass.

## Known limitations

- **One version for every world.** The on-demand servers run the fleet pin, because the
  client payload, the mods and the Fabric mappings are all pinned together and the
  assertions refuse anything else. A world on a different version means a second image and
  a second set of pins.
- **The launcher is not on the couch.** The couch keeps its own pre-launcher: its job is
  several players on one screen with pads assigned to seats, which the per-machine
  launcher does not do.
- **No late join.** Whoever is not at the pre-launcher when you press *Start now* is not in
  that session. Re-tiling live windows was deliberately not attempted.
- **Everyone is Steve or Alex.** Offline mode cannot fetch skins. Better Name Visibility
  answers the half that matters — telling each other apart at quarter-screen.
- **No terrain pre-generation.** Vanilla has no pregen command. If concurrent exploration
  stutters, lower Sodium's chunk-build thread count per client first.
