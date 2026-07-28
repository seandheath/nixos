# Minecraft on hydrogen — persistent server + couch split-screen

Two independent things, both on hydrogen (the ZBook next to the projector):

- **`modules/minecraft-server.nix`** — a vanilla server running as a system service.
  Always on, survives reboots, no login needed, backed up by borg.
- **`modules/minecraft-couch.nix`** — 1–4 GNOME icons that put that many tiled
  Minecraft clients on the projector, one gamepad each.

The design spec this was built from is `~/Downloads/specification.md`.

---

## Quick reference

| I want to… | Do this |
|---|---|
| Play on the couch | Click **Minecraft — N Players** in the GNOME app grid |
| Leave the game | `SUPER`+`SHIFT`+`Q` (returns to GNOME) |
| Get back to GNOME if something wedges | `sudo chvt 2`, or from another machine `ssh hydrogen 'sudo systemctl stop minecraft-couch@*'` |
| Add or update a mod | Edit the `couch` instance in Prism, then run `minecraft-couch-sync` |
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
3. *Edit Instance* → *Mods* → *Download mods*, and install:
   - **Controlify** — gamepad support and controller-driven menus
   - **Sodium** — renderer; the reason four clients are comfortable at all

   No AuthMe (it exists to let an *online* account log into an offline launcher —
   irrelevant here) and no Splitscreen Support (window placement is the
   compositor's job now).
4. *Edit Instance* → *Settings*:
   - **Memory:** 3 GB max. Not more — a bigger heap only lengthens GC pauses,
     which show up as stutter. 4 × 3 GB + the server's 6 GB fits the 31 GiB
     installed.
   - **Framerate:** cap at 60. Uncapped Minecraft eats every spare core for no
     visible benefit at quarter-screen.
5. Launch it once by hand, then in-game: press `F3`+`P` until it says
   *"pauseOnLostFocus: false"* so background windows keep rendering. Set video
   settings while you are there (render distance 8 is plenty).

### 2. Fan the instance out to four data directories

```console
$ minecraft-couch-sync
minecraft-couch-sync: 4 player directories ready under /home/sheath/.local/share/minecraft-couch
```

Prism refuses to run twice from the same data directory (its single-instance lock
is keyed on that path), so each player gets their own under
`~/.local/share/minecraft-couch/pN`. These are **not** four copies: `libraries`,
`meta`, `assets`, `java` and the instance's `mods` folder are symlinks back to
`~/.local/share/PrismLauncher`. You keep editing exactly one instance in the GUI.

**Re-run `minecraft-couch-sync` after any mod change or Minecraft update.** Each
player's `options.txt`, `config/` and saves are excluded from the sync, so their
video and controller settings survive it.

### 3. Pair the controllers and record their MACs

Bluetooth event device numbers are handed out in connection order, and three
identical Switch Pro Controllers also collide on `by-id` — so without this step
"player 1" would mean "whoever powered on first".

Pair all four (GNOME Settings → Bluetooth), then:

```console
$ bluetoothctl devices
Device 98:B6:E9:11:22:33 Pro Controller
Device 98:B6:E9:44:55:66 Pro Controller
Device 98:B6:E9:77:88:99 Pro Controller
Device 44:16:22:AA:BB:CC Xbox Wireless Controller
```

Put them in the `players` list at the top of `modules/minecraft-couch.nix`, in
the order you want the quadrants assigned, and change the names to the kids'
names while you are there:

```nix
players = [
  { name = "Ada";  mac = "98:B6:E9:11:22:33"; comment = "Switch Pro, blue grip"; }
  …
];
```

> **The names are load-bearing.** An offline UUID is a hash of the username, so
> renaming a player *after* they have played orphans that character's inventory,
> advancements and ender chest. Pick them once.

Rebuild (`nr`), then confirm:

```console
$ ls -l /dev/input/p*
lrwxrwxrwx 1 root root 6 … /dev/input/p1 -> event19
```

Until real MACs are filled in, the build prints a warning and the symlinks never
appear — deliberately a warning and not an assertion, so the server half of this
still deploys while you are pairing.

### 4. Play

Click **Minecraft — 4 Players**. Expect roughly 30–60 s before all four are in
the world; the launcher staggers them and places each window as it appears.

---

## How the launcher works

```
.desktop icon
  └─ minecraft-couch N                    runs inside the GNOME session
      └─ systemd  minecraft-couch@N       a REAL logind session on tty7
          └─ Hyprland (generated config)  tiles; no bars, idle or lock
              └─ minecraft-couch-spawn    places N windows by hyprctl address
                  └─ minecraft-couch-player i
                      └─ bwrap: tmpfs over /dev/input, one pad bound back
                          └─ prismlauncher -d …/pN --offline <name> --server 127.0.0.1:25565
```

Three decisions worth knowing when debugging:

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
the wrapper binds the *resolved* node (`event19`), not the `p1` symlink — SDL
enumerates `/dev/input/event*`, so a sandbox holding only `p1` would show the game
no gamepad at all.

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
both the local repo (`/data/borg`) and BorgBase nightly at 03:00.

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
| "Controller N is not connected" | Pad is asleep or unpaired. Wake it; `ls -l /dev/input/p*` to confirm |
| "Player N is not set up yet" | Run `minecraft-couch-sync` |
| Projector goes black and stays there | DRM master handoff failed. `sudo chvt 2` to return to GNOME; `journalctl -u minecraft-couch@4` for the Hyprland log |
| All characters move together | The bwrap isolation is not taking. Check `/dev/input/pN` are distinct event nodes — if two rules matched the same MAC, `bluetoothctl devices` and fix the `players` list |
| Only one window, or windows stacked | `minecraft-couch-spawn` could not match the window class. `hyprctl clients` during a session and check the class really contains "minecraft" |
| Client can't join: "Chat disabled due to missing profile public key" | `enforce-secure-profile` drifted back to true — it must be `false` alongside `online-mode=false` |
| Mods updated but only player 1 has them | `minecraft-couch-sync` |
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

That is a change to `minecraft-couch-session` and the unit only — the udev rules,
bubblewrap wrapper, window placement, sync script and desktop entries are all
unaffected. It costs one extra compositing pass.

---

## Known limitations

- **Everyone is Steve or Alex.** Offline mode cannot fetch skins. With four kids
  on one screen this is a genuine usability problem, not a cosmetic one — make
  sure nameplates are legible at quarter-screen, or add a skin mod.
- **No terrain pre-generation.** Vanilla has no pregen command, and the spec rates
  it polish rather than a requirement on this hardware. If concurrent exploration
  stutters, lowering Sodium's chunk-build thread count per client is the first
  lever to try; do not preemptively cap it.
- **Pascal is end-of-life.** `hardware.nvidia.package` is pinned to the
  `production` (580) branch in `hosts/hydrogen.nix`. Every branch in the current
  nixpkgs pin happens to be 580.142, so the pin is a no-op today — its job is to
  stop the nightly auto-update from moving the GPU onto a 590 branch that does not
  support this card. Revisit deliberately at the next NixOS release bump.
