# Minecraft on hydrogen — persistent server + couch split-screen

Three parts:

- **`modules/minecraft-server.nix`** — a vanilla server on hydrogen (the ZBook next to
  the projector), running as a system service. Always on, survives reboots, no login
  needed, backed up by borg. Carries the Vanilla Tweaks datapacks.
- **`modules/minecraft-couch.nix`** — one GNOME icon on hydrogen that opens a
  pre-launcher and then tiles up to four Minecraft clients on the projector, one
  gamepad each.
- **`packages/minecraft-client-mods.nix`** — the Fabric client mod set, shared by the
  couch clients and sulfur's desktop client.

The design spec this was built from is `~/Downloads/specification.md`.

---

## Quick reference

| I want to… | Do this |
|---|---|
| Play on the couch | Click **Minecraft (Couch)** in the GNOME app grid |
| Leave the game | `SUPER`+`SHIFT`+`Q` (returns to GNOME) |
| Get back to GNOME if something wedges | `sudo chvt 2`, or from another machine `ssh hydrogen 'sudo systemctl stop minecraft-couch'` |
| Add a player, or pair a controller | In the pre-launcher, before **Start playing** |
| Add or update a mod | Edit `packages/minecraft-client-mods.nix` and rebuild — the re-link is automatic |
| Add or update a datapack | Regenerate the zips into `packages/minecraft-datapacks/`, rebuild, restart the server |
| See what mods are installed | `minecraft-mods-link <instance>` prints the list |
| Check what a new controller sends | `minecraft-couch-menu --probe` |
| See who is connected | `sudo journalctl -u minecraft-server -f` |
| Run a server command | `echo "time set day" \| sudo tee /run/minecraft-server.stdin` |
| Restart the server | `sudo systemctl restart minecraft-server` |

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

## First-time setup

Everything below is one-time and stateful; Nix owns the plumbing, not the Prism
instance itself.

### 1. Create the Prism instance

Open **Prism Launcher** on hydrogen (it is in the app grid).

1. Add your real Microsoft account under *Accounts*. This is what unlocks offline
   launching — the four players are offline accounts, but Prism will not offer
   offline mode at all without one genuine account attached.
2. *Add Instance* → name it exactly **`couch`** → Minecraft **1.21.10** → **Fabric**.

   The version must equal the server's. Check with:
   ```console
   $ nix eval --raw ~/nixos#nixosConfigurations.hydrogen.pkgs.minecraft-server.version
   ```
3. **Do not install any mods here.** Nix supplies the whole set — including Controlify
   and Sodium, which used to be manual steps. `minecraft-couch-sync` (next step) wires
   it up. See [Mods and datapacks](#mods-and-datapacks).
4. *Edit Instance* → *Settings*:
   - **Memory:** 3 GB max. Not more — a bigger heap only lengthens GC pauses,
     which show up as stutter. 4 × 3 GB + the server's 6 GB fits the 31 GiB
     installed.
   - **Framerate:** cap at 60. Uncapped Minecraft eats every spare core for no
     visible benefit at quarter-screen.
5. Launch it once by hand, then in-game: press `F3`+`P` until it says
   *"pauseOnLostFocus: false"* so background windows keep rendering. Set video
   settings while you are there (render distance 8 is plenty).

### 2. Fan the instance out into one data directory per player

```console
$ minecraft-couch-sync
minecraft-couch-sync: 5 player director(ies) ready under /home/sheath/.local/share/minecraft-couch
```

With no arguments it syncs every player in the roster; with names, only those
(which is how the pre-launcher sets up a player you add from the couch).

Prism refuses to run twice from the same data directory (its single-instance lock
is keyed on that path), so each player gets their own under
`~/.local/share/minecraft-couch/<name>`. These are **not** full copies:
`libraries`, `meta`, `assets`, `java` and the instance's `mods` folder are
symlinks back to `~/.local/share/PrismLauncher`. You keep editing exactly one
instance in the GUI.

The sync also runs `minecraft-mods-link couch`, which points that one instance's
`mods` at the Nix store — so the chain is *player → canonical instance → store*,
and a rebuild that changes the mod list reaches everybody on the next sync.

**Re-run `minecraft-couch-sync` after any mod change or Minecraft update.** Each
player's `options.txt`, `config/` and saves are excluded from the sync, so their
video and controller settings survive it.

### 3. Pair the controllers

Nothing needs recording. Pair them from the pre-launcher itself: click
**Minecraft (Couch)**, choose **Pair a controller**, hold the pad's SYNC/PAIR
button until its lights flash, and pick it out of the scan results.

There is no chicken-and-egg problem with an unpaired first pad — every screen
also accepts the keyboard (hydrogen has a wired Dell KB216), so you can reach the
pairing screen with no controller at all.

Confirm afterwards:

```console
$ ls -l /dev/input/couchpad-*
lrwxrwxrwx 1 root root 6 … /dev/input/couchpad-event19 -> event19
```

One symlink per connected pad. It does not matter which is which — players say
who they are at session start.

### 4. Play

Click **Minecraft (Couch)**. Choose **Start playing**, and for each pad in turn
the player holding it picks their name (or **Nobody (sit out)**, or **Start now**
to skip the remaining pads). Expect roughly 30–60 s before everyone is in the
world; the launcher staggers them and places each window as it appears.

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
rejects bad names as you type, and a Nix assertion catches a bad seed at build
time.

`LuckyObserver` is seeded alongside the kids so sheath can play from the couch as
well as from sulfur — though not from both at once, since the server rejects a
duplicate login of the same username.

---

## Mods and datapacks

Two different mechanisms, and the difference matters:

| | Where it runs | Where it lives | Who has to install it |
|---|---|---|---|
| **Client mods** | the client, Fabric | `packages/minecraft-client-mods.nix` | every client, separately |
| **Datapacks** | the server, vanilla | `packages/minecraft-datapacks/` | nobody — the server pushes them |

**The server has no mod loader and is never getting one.** Datapacks are vanilla
data-driven content; a phone or laptop joining over the tunnel still installs
nothing. Anything that would need Fabric on the server breaks that for every remote
device at once.

### Client mods

| Mod | What it is for |
|---|---|
| Sodium | the renderer — the reason four clients on one GPU are comfortable |
| Controlify | gamepad support and controller-driven menus |
| Xaero's Minimap | minimap and waypoints |
| Better Name Visibility | legible nameplates at quarter-screen |
| Jade | what am I looking at |
| Effortless Crafting | craft using items in reachable chests, no hauling |
| Fabric API, YACL, Mod Menu, Cloth Config | dependencies of the above |

There is **no recipe viewer**, and that is not an oversight — see below.

`minecraft-mods-link <instance>` makes an instance's mods folder a symlink to the
store path holding all ten jars. Both machines point at the same list, so they
cannot drift.

**This runs itself.** `minecraft-mods-link.service` re-links on boot and on any switch
that changes the jar set — the store path is baked into `ExecStart`, so a changed mod
list changes the unit and switch restarts it. Instances are named per host in
`services.minecraftClientMods.instances`. It is idempotent (a correct link is reported
and left alone) and an instance that does not exist yet is skipped, not an error.

The one case it does *not* cover: **creating a new instance** under an otherwise
unchanged configuration. Nothing changed, so nothing restarts. Run
`minecraft-mods-link <instance>` by hand once, or `systemctl restart
minecraft-mods-link`.

> **The game root is not always `.minecraft`.** Prism 11 creates instances with a
> plain `minecraft/`; the dotted name is the MultiMC-era layout, kept only for
> inherited instances. Both `minecraft-mods-link` and `minecraft-couch-sync` resolve
> it at runtime. Getting this wrong fails *quietly* — the link lands where Prism
> never looks, the Mods tab shows an empty list, and a stray `.minecraft/` appears
> beside the real game root. If the Mods tab is empty, check which one the instance
> actually uses before anything else.

> **Prism's GUI can no longer install mods into a linked instance** — `mods/` is a
> read-only store path. That is the trade for one list driving both machines. Add
> mods in Nix instead. Browsing the *Mods* tab still works; only installing does not.

To add or update one: find the version on Modrinth for `loader=fabric,
game_version=1.21.10`, add an entry to `packages/minecraft-client-mods.nix` (the
header has the API query and the hash-conversion one-liner), rebuild, then re-link.

An assertion ties the pinned `mcVersion` to `pkgs.minecraft-server.version`, so a
nixpkgs bump that moves the server off 1.21.10 fails the build instead of showing
four children an incompatible-mod screen.

### Why there is no recipe viewer

**Since Minecraft 1.21.2 the recipe list lives on the server and is no longer sent to
clients.** A client-only viewer therefore cannot enumerate recipes against a vanilla
server. This is a vanilla protocol change, not a property of any particular mod, so
all three candidates are affected:

| | Status on 1.21.10 |
|---|---|
| **JEI** | Works, but every join prints *"JEI is missing recipes. Please install JEI on the server"*. Item list fine, recipe lookup dead. |
| **EMI** | Never shipped past `1.1.24+1.21.1`, i.e. it stops right before the change. |
| **REI** | Has a client-side fallback, but it breaks for any recipe **unlocked in-game** ([#2063](https://github.com/shedaniel/RoughlyEnoughItems/issues/2063)) — and Unlock All Recipes unlocks all of them, so it would fail on nearly every item. |

JEI was installed first and removed once the chat error made the cause clear.

**The gap is narrower than it sounds.** Unlock All Recipes leaves every player's
vanilla recipe book complete and searchable, so *"how do I make X"* is covered. What
is missing is reverse lookup — *"what is this ingredient for?"* — and the stations the
recipe book ignores, namely brewing and smithing.

**To revisit:** REI's fix ([#2065](https://github.com/shedaniel/RoughlyEnoughItems/pull/2065))
merged 2026-07-29 but is unreleased on every branch as of 2026-08-04. Check for a REI
build published after that date supporting the server's version; if one exists, adding
it to the mod list is the entire change.

Two alternatives were considered and rejected. **Running Fabric plus JEI on the
server** would fix it properly, but the server would stop being the stock jar and the
"any unmodded device can join over the tunnel" guarantee would need re-verifying —
JEI's jar requires Fabric API server-side, not just the loader. **Downgrading to
1.21.1**, the last version before the change, would let EMI work fully client-side,
but the world cannot be downgraded (no path back from `DataVersion` 4556) and 1.21.1
predates `pause-when-empty-seconds` — verified absent from its server jar — which is
the only reason this always-on server idles at 0.10% of a core instead of ticking
continuously.

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

## Playing from sulfur

sulfur has its own Prism instance, `Hydrogen`, and joins at `10.0.0.10:25565` over
the LAN or the tunnel. One-time setup:

1. *Edit Instance* → *Version* → install **Fabric** (the instance started out
   vanilla, which cannot load any of the mods above).
2. ```console
   $ minecraft-mods-link Hydrogen
   minecraft-mods-link: Hydrogen -> /nix/store/…-minecraft-client-mods-1.21.10
   ```
   Only needed this once, because the instance did not exist when the service last
   ran. After that `minecraft-mods-link.service` keeps it current on every rebuild.

Note the one-login-per-username rule: if sheath is playing `LuckyObserver` from
sulfur, the couch cannot also be `LuckyObserver`.

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
                          └─ prismlauncher -d …/<name> --offline <name> --server 127.0.0.1:25565

mods, two symlink hops from every player ("minecraft" here is the instance's game
root, resolved at runtime — Prism 11 uses that name, MultiMC-era ones ".minecraft"):
  …/minecraft-couch/<name>/instances/couch/minecraft/mods
    └─ …/PrismLauncher/instances/couch/minecraft/mods   (minecraft-mods-link)
        └─ /nix/store/…-minecraft-client-mods-1.21.10
```

Four decisions worth knowing when debugging:

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

Clients currently run under **XWayland**, which needs no configuration and whose
usual complaint (HiDPI blurriness) is irrelevant at 1080p.

If that turns out to cost too much, switch to native Wayland by adding this to the
instance's JVM arguments in Prism:

```
-Dorg.lwjgl.glfw.libname=/run/current-system/sw/lib/libglfw.so
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

The couch **client** state is backed up separately and for a different reason:

```
~/.local/share/minecraft-couch      roster + each player's settings
~/.local/share/PrismLauncher        the canonical instance + accounts.json
```

Nobody loses a character or a build if these go — the world is server-side. What
they hold is what the flake *cannot* rebuild: `players.json` (authoritative once
created, so anyone added from the couch exists only there), each child's
`options.txt` and Controlify bindings, and the Microsoft account that unlocks
offline launching. Prism's `assets`, `libraries`, `meta`, `java` and `cache` are
excluded — about a gigabyte that Prism refetches on first launch.

> **Both directories are pre-created by `systemd.tmpfiles`, deliberately.** The
> borg jobs run with `failOnWarnings = true`, and borg treats a missing source
> path as a warning and exits 1 — so on a machine where Prism had never been
> opened, adding these paths would have failed the *entire* nightly backup,
> Nextcloud and Immich included. Do not remove the tmpfiles rules without also
> removing the paths.

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
| "its game folder could not be created" after adding a player | The Prism `couch` instance does not exist yet (step 1). Create it, then `minecraft-couch-sync` |
| Pad cannot move the cursor in the pre-launcher | Its D-pad reports codes not in the accepted set. `minecraft-couch-menu --probe`, press the D-pad, and widen the list in `modules/minecraft-couch.nix`. The left stick and the keyboard both work meanwhile |
| Projector goes black and stays there | DRM master handoff failed. `sudo chvt 2` to return to GNOME; `journalctl -u minecraft-couch` for the Hyprland log |
| All characters move together | The bwrap isolation is not taking. Check the nodes handed to each `minecraft-couch-player` are distinct — `ls -l /dev/input/couchpad-*` should show one symlink per pad, each resolving to a different `eventN` |
| Only one window, or windows stacked | `minecraft-couch-spawn` could not match the window class. `hyprctl clients` during a session and check the class really contains "minecraft" |
| Client can't join: "Chat disabled due to missing profile public key" | `enforce-secure-profile` drifted back to true — it must be `false` alongside `online-mode=false` |
| Mods updated but only player 1 has them | `minecraft-couch-sync` |
| Prism won't install a mod ("read-only" / permission denied) | Expected — `mods/` is a store symlink. Add it to `packages/minecraft-client-mods.nix` instead |
| Mods tab is empty right after linking | The link went to the wrong game root. `ls -la <instance>/` — if both `minecraft/` and `.minecraft/` exist, delete the one Prism is not using (its log says `Started watching …/mods`) and re-run `minecraft-mods-link` |
| A mod is missing after a rebuild | `systemctl status minecraft-mods-link` — it should have re-linked. If the instance was created since the last switch, run `minecraft-mods-link <instance>` once |
| Datapacks not in effect | `echo "datapack list" \| sudo tee /run/minecraft-server.stdin`, then check the journal. If they are listed as incompatible, the server moved past 1.21.11 — regenerate the zips |
| `minecraft-mods-link` refuses: "nowhere safe to stash it" | Both `mods/` and `mods.stateful` hold real files. Merge or delete one by hand |
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
pre-launcher, bubblewrap wrapper, window placement, sync script and desktop entry
are all unaffected. It costs one extra compositing pass.

---

## Known limitations

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
