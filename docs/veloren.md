# Veloren on hydrogen — persistent server

**`modules/veloren-server.nix`** — a [Veloren](https://veloren.net) server running as a
system service on hydrogen. Always on, survives reboots, no login needed, backed up by borg.

Veloren is an open-world voxel RPG. Unlike Minecraft it has no couch/split-screen mode here —
each player uses their own machine, on the LAN or over the WireGuard tunnel.

There is **no `services.veloren` in nixpkgs**. nixpkgs ships one derivation, `pkgs.veloren`,
containing both `veloren-server-cli` and `veloren-voxygen` (the client); the systemd unit is
hand-written in `modules/veloren-server.nix`.

---

## Quick reference

| I want to… | Do this |
|---|---|
| Play | Run `veloren-voxygen`, choose **Multiplayer**, server `10.0.0.10:14004` |
| See who is connected | `sudo journalctl -u veloren-server -f` |
| Restart the server | `sudo systemctl restart veloren-server` |
| Make someone an admin | `sudo systemctl stop veloren-server && sudo -u veloren VELOREN_USERDATA=/var/lib/veloren veloren-server-cli admin add <name> && sudo systemctl start veloren-server` |
| Check the version a client needs | `nix eval --raw ~/nixos#nixosConfigurations.hydrogen.pkgs.veloren.version` |

---

## Version lock-step — read this before installing a client

**Veloren refuses connections between mismatched versions.** The pin is currently **0.17.0**.

The server and the client are literally the same derivation, so the reliable way to get a
matching client is to install `pkgs.veloren` from this flake. `hosts/hydrogen.nix` and
`hosts/sulfur.nix` both do.

**Do not use Airshipper** (the official launcher). It self-updates to upstream's *weekly
nightly* builds, which will never match a 0.17.0 release server. nixpkgs' `airshipper` is
0.16.0 and does not help either.

For a non-NixOS machine, install the 0.17.0 release build from
<https://gitlab.com/veloren/veloren/-/releases> — not the nightly channel.

When `flake.lock` is updated and `pkgs.veloren` moves, **every** client must move with it, in
the same rebuild. Expect a flag day.

---

## Network and security model

The server runs with `auth_server_address: None`. That means it performs **no identity
verification at all** — anything that can open a TCP connection to 14004 may claim to be any
username. This is the same posture, and the same reasoning, as the Minecraft server's
`online-mode=false` (see `docs/minecraft.md`): the household has no veloren.net accounts.

**Reachability is therefore the authentication boundary.**

- 14004/tcp (game) and 14006/udp (server-browser query) are opened only on `br0`
  (`hosts/hydrogen.nix`), never globally.
- hydrogen has **no `wg0`**. The WireGuard hub lives on the router
  (`vpn.luckyobserver.com`, tunnel `10.40.0.0/24`) and remote peers route to hydrogen's LAN
  address `10.0.0.10` — so tunnel traffic arrives on `br0` exactly like LAN traffic. The
  single `br0` rule covers both.
- The router forwards only `51820/udp`, so 14004 is not reachable from the internet.

**Re-verify that last point after any router change.** From a phone on cellular:

```console
$ nc -vz <wan-address> 14004
nc: connect to <wan-address> port 14004 (tcp) failed: Connection refused
```

Residual risk, accepted: any enrolled peer can log in as any username.

The server-cli's web/metrics endpoint listens on `127.0.0.1:14005` and is left at that
default — loopback only. Reach it, if ever needed, over an SSH port-forward.

---

## `world_seed` is the world — do not change it

Veloren does **not** store the world. It regenerates it from `world_seed` on every start
(about 6 seconds), and `/var/lib/veloren/server/saves/` holds only the terrain *diffs* players
have made plus the character SQLite database.

Changing `world_seed` in `modules/veloren-server.nix` therefore replaces the world wholesale
and orphans every player-made change and waypoint — while leaving the characters intact and
now standing in unfamiliar terrain. Treat it as a database identifier, not a tunable. It is
currently `20260803`, the date the world was created.

---

## Configuration

`settings.ron` is declarative. `ExecStartPre` reinstalls it from the Nix store on every start,
so a hand-edit to `/var/lib/veloren/server/server_config/settings.ron` is reverted by the next
restart — the same contract as `services.minecraft-server.declarative = true`. Edit the module
and rebuild instead.

It is a *partial* file: the server fills every unset field from its own defaults, so only the
values that matter are named. Notable ones:

- `max_view_distance: Some(30)` — the dominant lever on server CPU, exactly as `view-distance`
  is for Minecraft. Upstream defaults to 65 chunks, far more than this box should spend given
  it also runs the Minecraft server, immich and ollama on one 6c/12t Xeon E-2176M. Raise it if
  players actually complain about terrain pop-in.
- `max_players: 10`

These files in the same directory are genuinely runtime-editable — the server rewrites them in
response to in-game commands — and are deliberately left stateful, *not* managed by Nix:
`admins.ron`, `banlist.ron`, `whitelist.ron`, `server_physics_force.ron`.

### Admins

A player must have logged in once (which creates the name) before being promoted. The
`admin add` subcommand wants exclusive access to the database, so stop the service first:

```console
$ sudo systemctl stop veloren-server
$ sudo -u veloren VELOREN_USERDATA=/var/lib/veloren veloren-server-cli admin add sheath
$ sudo systemctl start veloren-server
```

---

## Resource footprint

Measured against 0.17.0 with this configuration:

| | |
|---|---|
| Startup (worldgen → accepting connections) | ~6 s |
| Peak RSS | ~925 MiB |
| State dir after a short run | ~5 MiB |

Much lighter than the Minecraft JVM's 6 GiB heap — the world being procedural rather than
stored is most of why.

---

## Backups

`/var/lib/veloren` is in `backupPaths` in `modules/backup.nix`, so both borg jobs (local
`/data/borg` and remote BorgBase) pick it up.

Known limitation, accepted: `veloren-server-cli` exposes no console FIFO, so unlike Minecraft
there is no way to checkpoint it before the archive, and borg can capture
`saves/db.sqlite` mid-write. This was left alone rather than wrapped in a stop/start dance —
the world is not in the backup at all (it regenerates from `world_seed`), so the only exposure
is a torn character DB, recoverable from the previous night's archive.
