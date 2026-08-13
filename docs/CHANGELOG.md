# Changelog

## [Unreleased]
### Added
- `modules/auto-update.nix`: a failed nightly `nixos-upgrade` now raises a critical
  desktop notification. Nothing watched unit state before, so a failed rebuild left a
  red line in a journal nobody reads — the same silent-wrongness that let the fleet sit
  six weeks past 25.11's EOL. It matters more now: the five laptops track unstable with
  the kernel and nvidia driver unpinned, so a failed rebuild is an expected event, and
  an unnoticed one means the machine quietly stops updating.
  - **Two units, because one does not work.** `nixos-upgrade-notify.service` fires via
    `OnFailure=` and catches somebody sitting at the machine at 04:45. The user unit
    `nixos-upgrade-failed-notify.service` (`WantedBy=graphical-session.target`)
    re-checks `systemctl is-failed` at login, which is the case that actually happens:
    the timer is `Persistent=true`, so a laptop that was off overnight runs its
    catch-up during boot and fails *before* any session exists to be notified.
  - Enumerates live `/run/user/*/bus` sockets rather than hardcoding a username, so it
    works unmodified on the kids' laptops where the logged-in user is not `sheath`.
  - Every notification path ends in `|| true`; a broken notifier must not turn one
    failed unit into two. The journal line is the record, the popup is a courtesy.
  - Reads systemd's own unit state instead of writing a marker file — a marker would
    need its own `modules/impermanence.nix` entry to survive sulfur's tmpfs root.
  - **Known gaps.** Unit state does not survive a reboot, so a failure followed by a
    reboot-before-login goes unseen. And on the kids' laptops this notifies the child,
    who cannot act on it, rather than sheath, who can — the four machines where nobody
    is watching are precisely the ones this does not really cover. Both need an
    off-box channel (ntfy on hydrogen is the obvious candidate); deliberately deferred.

### Fixed (first real catch by the nightly-failure notifier)
- **`hosts/sulfur.nix`: force `SendSIGKILL` on `asus-shutdown.service`.** The 2026-08-13
  nightly built and switched cleanly, then exited 4 because a unit would not restart.
  asusctl 6.3.x ships `asus-shutdown`, which traps SIGTERM and logs *"Deferring exit
  until deferred shutdown apply reaches a safe completion point"* — with upstream's
  `SendSIGKILL=no` and `TimeoutStopSec=45`, systemd has no way to reap it if that point
  never arrives. It burned 45 s in `stop-sigterm`, 45 s in `final-sigterm`, entered
  failed mode, and left the old PID running against the old store path for 24 h. The
  switch only needed to restart the unit because asusctl's store path moved, which on an
  unstable channel is most nights.
  - `restartIfChanged = false` does **not** avoid this: the unit is
    `PartOf=asusd.service`, so an asusd restart propagates a stop no matter what we ask
    for. The fix has to sit at the kill layer — `SendSIGKILL = mkForce true` plus
    `TimeoutStopSec = 10`, which NixOS emits as a drop-in over the packaged unit.
  - SIGKILLing a *shutdown* handler mid-rebuild costs nothing: at real shutdown systemd
    kills it anyway once its own timeout expires, and asusd re-applies state on start.
- **`hosts/sulfur.nix`: `ExecCondition` on `dock-monitors-hotplug.service`.** The udev
  rule fires on every DRM change event, including those with no graphical session behind
  them — at boot before login, and during a switch that restarts the GNOME session under
  us. The script then reaches a dead session bus (`Remote peer disconnected`, or a
  missing `/run/user/1000/bus`) and exits 1, which with `startLimitBurst = 1` leaves a
  failed unit. That is not just journal noise: `switch-to-configuration` counts failed
  units, so it turned an otherwise clean nightly into a failure report. A failing
  `ExecCondition` marks the unit *skipped* rather than failed, so a genuine DBus error
  inside a live session still surfaces.

### Fixed (unstable fallout on sulfur — the laptop would not boot)
- **`hardware/sulfur.nix`: `pcie_aspm=off`.** 26.11 (Linux 6.18.44) would not boot: the
  Realtek RTS525A card reader at `0000:2c:00.0` stormed correctable PCIe AER errors —
  `status=0x00001000`, bit 12, Replay Timer Timeout — every ~150 µs, four log lines
  each. The kernel spent the whole boot in the AER handler. `lspci` confirmed the cause:
  `ASPM L0s L1 Enabled` with all L1 substates on, `T_PwrOn=60us`, i.e. the link kept
  dozing off and failing to complete a replay in time.
  - **The fault was not new.** 26.05 logs the identical error, same device, same bit —
    just ten per boot, after which the reader runtime-suspends and goes quiet. 6.18.44
    never lets it settle. The channel move did not create this; it stopped hiding it.
  - After the fix, AER errors this boot: **zero**, down from ten per boot on 26.05.
    That link had never been healthy.
- `hardware/sulfur.nix`: dropped `rtsx_pci_sdmmc` from `boot.initrd.availableKernelModules`.
  Did *not* fix the hang (the fault is below any driver) but is correct regardless —
  root is LUKS-on-NVMe and the reader is not on the boot path.
- **`hosts/sulfur.nix`: `NVreg_DynamicPowerManagement=0x00` set explicitly.** The morning's
  RTD3 freeze fix had silently reverted. `powerManagement.finegrained = false` does not
  disable RTD3 — it omits the modparam and lets the driver default apply. 595.71.05
  defaulted to 0; 610.57.04, which `nvidiaPackages.latest` became on unstable, defaults
  to 3 and enables RTD3. Verified on the running system: `DynamicPowerManagement: 3`,
  `power/control: auto`. An absent modparam means "driver default", not "off".

### Changed (pinning policy)
- `hosts/sulfur.nix`: **kernel unpinned** (`boot.kernelPackages = pkgs.linuxPackages_6_18`
  removed). The pin was already inert — unstable's default *is* 6.18.44 — and would only
  have frozen the laptop on 6.18 long after nvidia-open could handle newer.
- `hosts/sulfur.nix`: **`nvidiaPackages.latest` deliberately left unpinned**, unlike
  hydrogen's `production`. Freezing the driver trades a loud breakage for a silent stale
  one, which is the failure mode that kept this fleet six weeks past 25.11's EOL. The
  RTD3 defence is the modparam, which survives driver bumps.
- `packages/qwen-code.nix`, `packages/ghidra-reva.nix`: rewrote justifications that still
  cited nixos-25.11. Both were misleading in the dangerous direction — read literally
  they invited deleting a package that is still load-bearing. qwen-code stays because
  nixpkgs is *behind* (unstable 0.16.0 vs local 0.21.1); ghidra-reva stays because ReVa
  7.3.0 ships no asset for unstable's ghidra-bin 12.1.2, not because of any version floor.
- Audited every other pin. `jackify`, `imjtool`, the Minecraft mod/payload set and
  `minecraft-version.nix` are all `fetchurl`/hash-pinned and channel-independent;
  hydrogen's `postgresql_17` and `nvidiaPackages.production` are untouched (still 26.05);
  `modules/opencode.nix`'s vLLM workaround is still required — `services.vllm` remains
  absent on unstable.

### Changed (fleet: split channels — 5 laptops to nixos-unstable, hydrogen stays 26.05)
- **This supersedes the "Deliberately NOT nixpkgs-unstable" note in the 26.05 entry
  below.** That note argued the risk was unattended nightly rebuilds on four kids'
  laptops nobody is watching. The risk is unchanged and was accepted deliberately;
  all five laptops track unstable in `system.autoUpgrade`.
- `flake.nix`: added `nixpkgs-unstable` (nixos-unstable) and `home-manager-unstable`
  (HM master, follows it). `nixpkgs` stays `nixos-26.05` and now serves hydrogen
  alone. `sops-nix`, `disko`, `cclaude`, `nix-index-database` keep one instance each
  following stable — they contribute modules that build against the host's `pkgs`, so
  per-channel copies would double those lock nodes for nothing. Accepted consequence:
  `nix-locate` on a laptop describes 26.05's package set, not its own.
- `flake.nix`: `commonModules` became a function of the channel's home-manager, and
  hosts are built through a new `mkHost { channel, hostName, extraModules }`. A host's
  channel is now declared in exactly one place; hydrogen's system derivation is
  byte-identical across the refactor (`nwv3agkb…`, verified before and after).
- `modules/fleet-channel.nix` (new): declares `fleet.channel`, set by `mkHost`.
- `modules/auto-update.nix`: derives BOTH the `--override-input` target name and the
  branch from `fleet.channel`. The input name matters as much as the branch here —
  `nixpkgs` is still a real input of this flake, so handing a laptop
  `--override-input nixpkgs <stable>` would be accepted, would beat `flake.lock`, and
  would drag it back to 26.05 nightly while reporting success. Same silent-success
  shape as the six-week EOL drift; now unrepresentable.
- `packages/minecraft-version.nix` (new): the 1.21.10 hold and the vanilla jar
  url/sha1, lifted out of the overlay in `modules/minecraft-server.nix`. The version
  can no longer be a property of whichever channel a host builds from.
- `modules/minecraft-client.nix`: the client-vs-server assertion was gated on
  `services.minecraft-server.enable`, i.e. hydrogen only, on the reasoning that
  hydrogen failing to build caught the drift for everyone. False once hydrogen and the
  clients are on different channels. It now compares the client payload against the
  fleet pin and fires on every host that imports the module.
- `packages/minecraft-client-launcher.nix`: takes a `toolPkgs` argument;
  `modules/minecraft-client.nix` passes the **stable** nixpkgs so `portablemc` and the
  JVM stay identical fleet-wide. f11c4af had to hand-rewrite this launcher when
  portablemc went 4.4.1 (Python) → 5.0.3 (Rust) and four CLI flags moved — a runtime
  break no build catches, which on unstable would land at 04:00 on a child's laptop.
- `modules/steam.nix`: `permittedInsecurePackages` emptied. It carried
  `electron-39.8.10` for Heroic 2.20.1; unstable ships Heroic 2.22.0 on
  electron-41.10.3, and every host importing this file is now unstable (hydrogen does
  not import it). Removed rather than left stale — a dead entry silently re-permits
  that exact package if anything pulls it back.
- `packages/jackify.nix`: `appimageTools.extractType2` → `extract` (renamed upstream).
- `modules/packages-desktop.nix`: dropped `gemini-cli`. nixpkgs marks it for removal —
  Google moved unpaid and AI Pro/Ultra tiers to Antigravity CLI — so it is leaving the
  tree rather than merely going stale. `packages/qwen-code.nix` (a gemini-cli fork) and
  `aider-chat` cover the same ground. sulfur-only: `modules/workstation.nix` is imported
  by `hosts/sulfur.nix` alone, so hydrogen and the kids' laptops never carried it.
- Eval is now warning-free on all six hosts except the Nextcloud notice below.

### Deferred
- **Nextcloud 32 → 33 on hydrogen.** nixpkgs warns that 33 is available and that
  `services.nextcloud.package` is pinned to `nextcloud32`. This is not a config defect
  and there is no separate way to silence it: declaring `nextcloud33` *is* the upgrade,
  and it runs a schema migration against the live instance. hydrogen currently reports
  `version: 32.0.13.1`, `needsDbUpgrade: false`, `maintenance: false` — healthy, and one
  clean major step away from 33 (Nextcloud refuses multi-major jumps). Wants a Borg
  restore point and a maintenance window, not a drive-by.

### Added
- `modules/family/peers.nix`: a `guests` attrset, and the first entry in it — a
  wgfam peer at `10.41.0.30` for a relative who wants to play Minecraft from
  outside the house. Separate from `mobile` because that set means "a household
  device with no Nix config" and this means "not the household"; who holds the
  private key is the thing a reader needs to see at a glance. `vpn-hub.nix` folds
  the new set into wgfam's peer list.
- Their key was generated on their own machine and only the public half entered
  this repo, so unlike `gen-mobile-peer.sh` there is no moment where the private
  key exists on an admin box or crosses a chat window.
- **What a guest key actually reaches, recorded because it is more than the name
  suggests:** wgfam's port list in `hosts/hydrogen.nix` is per-INTERFACE, not
  per-peer, so this key reaches `80`/`443` as well as `25565` — the Nextcloud,
  Immich, Paperless and Calibre vhosts. Those are password-authenticated, so what
  becomes reachable is a login page rather than any data. Accepted deliberately.
  If that stops being an acceptable trade the answer is a third hub (`wgguest`)
  carrying only `25565`, NOT a source-address match on wgfam — the hubs are split
  by interface precisely so `iptables -S` shows the boundary.

### Changed (fleet: nixpkgs 25.11 -> 26.05, because 25.11 is EOL)
- **Why.** Signal Desktop refused to start: it hard-expires roughly 90 days after
  release and the fleet was pinned to `signal-desktop` 8.9.1. The channel, not the
  package, was the problem — `nixos-25.11` stopped receiving commits on 2026-06-30,
  so no backport of any kind was ever going to arrive, for Signal or for anything
  else. `nixos-26.05` (tip 2026-08-09) carries 8.21.0, five days behind upstream.
- `flake.nix`: `nixpkgs` -> `github:nixos/nixpkgs/nixos-26.05`, `home-manager` ->
  `release-26.05`. Every input that `follows` nixpkgs moved with it; `nix-gaming`,
  `chaotic` and `pi-flake` deliberately do not follow and were left alone.
- Deliberately NOT nixpkgs-unstable. Both branches ship the same Signal today, and
  four of these hosts are the kids' laptops on an unattended nightly `autoUpgrade` —
  unstable turns every night into a chance of a broken rebuild nobody is watching.
  The failure here was staying six weeks past EOL, not stable moving too slowly.

### Fixed (26.05 migration fallout)
- `home/neovim.nix`: `nodePackages.bash-language-server` -> top-level
  `bash-language-server` (the `nodePackages` set was removed), and
  `programs.neovim.extraLuaConfig` -> `initLua` (home-manager rename).
- `hosts/sulfur.nix`: dropped `services.asusd.enableUserService`; asusd no longer
  needs a per-user service and defining the option is now a hard assertion failure.
- `hosts/hydrogen.nix`: `networking.wireless.enable` needs `lib.mkForce false`.
  26.05's NetworkManager module defines it `true` outright (dbus-controlled
  wpa_supplicant) rather than as a default, and GNOME pulls NetworkManager in on
  hydrogen, so a plain `false` is now a definition conflict. hydrogen has no wifi.
- `modules/immich.nix`: dropped `database.enableVectors`. The option is gone in 26.05
  along with pgvecto.rs; VectorChord is the only backend and is on by default.
- `modules/minecraft-server.nix`: overlay holding `minecraft-server` at 1.21.10.
  26.05 ships 1.21.11, which the version-lockstep assertions correctly refused —
  Fabric intermediary mappings, the Modrinth mod pins and the client payload are all
  still 1.21.10. 1.21.11 builds do exist on Modrinth for the pinned mods, so the
  migration is possible; it is deliberately deferred to its own change rather than
  riding along on a channel bump. nixpkgs no longer exposes a per-patch attribute for
  1.21.10, hence the explicit jar `src`.
- `packages/minecraft-client-launcher.nix`: rewritten for portablemc 5.0.3, a Rust
  rewrite of the 4.4.1 Python tool. `minecraft-client` died at
  `error: unexpected argument '--work-dir' found` — a runtime break a build check was
  never going to catch, on sulfur and on every couch client. Four flags moved:
  `--work-dir` -> `start --mc-dir`, `-s`/`-p` -> `--join-server`/`--join-server-port`,
  `--timeout` deleted outright, and only `--main-dir` is still a global option.
- **`--bin-dir` is the trap.** 5.0.3 documents it as derived from `--mc-dir` and then
  gives the default as `<main-dir>/bin/`; the second is what it does, so with only
  `--mc-dir` set the LWJGL natives extract into the read-only payload and the launch
  dies on `Read-only file system (os error 30)`. Under 4.x the bin dir came off the
  work dir and this cost nothing. Now stated explicitly.
- The offline guarantee got *stronger* in the process. `--timeout 10` only bounded how
  long the version-manifest fetch could stall a launch; `--fetch-exclude-all` means the
  call is never made. Re-verified in a network namespace: resolves both versions,
  78 libraries, 4403 assets, loads the JVM, exits 0.
- Every "why" comment citing portablemc's Python internals (`standard.py`,
  `download.py`, `auth.py`, `cli/__init__.py`) was replaced with observed 5.0.3
  behaviour — those line numbers describe a program that no longer exists. Same for
  the `use-builtin-java.patch` note: 5.0.3 carries no patches, and `--jvm` now also
  serves to keep `--jvm-policy` from fetching a JVM.
- `modules/auto-update.nix`: `--override-input nixpkgs` still pointed at
  `nixos-25.11`, six weeks after that branch went EOL. It is imported by
  `hosts/hydrogen.nix` and `modules/family/profile.nix`, so five of six hosts were
  rebuilding nightly against a frozen tree — and the job never failed, which is why
  nothing surfaced it. Post-migration the drift would have been worse than stale: the
  override beats `flake.lock`, so a nightly run would have pulled the fleet back onto
  EOL nixpkgs, silently undoing this migration on the four laptops nobody watches.

### Known issues
- `hosts/sulfur.nix`: `../modules/farcry2.nix` is commented out. Its mod archive is a
  `requireFile` pin and the 7z was garbage-collected — the extracted tree survived but
  the source did not, so the 26.05 stdenv change (new derivation hash) has nothing to
  build from. Re-download `FC2-RealismPlusRedux-326-v1.2.5.7z` from
  nexusmods.com/farcry2/mods/326, `nix-store --add-fixed sha256 <file>`, uncomment.
  Installed game files are unaffected; only `fc2-apply-mods` is missing.
- home-manager warns that `programs.vscode.package` is a VSCodium fork while
  `programs.vscode` now writes to Visual Studio Code's paths. Migrating to
  `programs.vscodium` moves the config location, so it was left for a separate change.
### Changed (sulfur: the tunnels are NetworkManager profiles, and the panel toggle is safe)
- **Why.** NetworkManager manages WireGuard devices whether or not we want it to, so the real
  choice is not "NM or not" but "NM as a spectator or NM as the owner" — and the spectator is
  the dangerous one, offering a GNOME toggle that flushes address and routes out from under a
  systemd unit that goes on reporting success. Handing NM the whole configuration makes the
  same toggle correct: deactivating tears the tunnel down, activating rebuilds it from config
  NM actually holds. It also puts real status in the panel, which during the 2026-08-09
  incident was the only source that told the truth while `systemctl` and `wg show` both
  reported health.
- `wg0`, `wgadm` and `fleet` on sulfur move from `networking.wg-quick.interfaces` to
  `networking.networkmanager.ensureProfiles.profiles`. `wgadm` is `autoconnect = true`; `wg0`
  and `fleet` stay manual, switched from the panel or `nmcli connection up/down`.
- **Keys did not move.** `wireguard.private-key-flags = 1` marks them agent-owned and
  `nm-file-secret-agent` hands each one to NM from the sops path that tunnel already used as
  its `privateKeyFile`. No new secret, no `secrets.yaml` edit, no `gen-family-secrets.sh`
  change, and the key never lands in a connection file. `environmentFiles` was rejected for
  the opposite reason — it would have required a new `KEY=value` secret and written the key
  into the profile.
- `wg0` keeps a hostname endpoint, which is now safe. Under `wg-quick` it was not: `wg-quick`
  resolves during `wg setconf`, so a boot that beat the Wi-Fi killed the unit for the session
  (2026-08-08 and -09). NM resolves asynchronously and retries the activation. Its
  `table = "off"` plus the `postUp`/`postDown` metric-1000 pair collapse into one
  `ipv4.route-metric = 1000`.
- **hydrogen deliberately keeps `wg-quick` for `fleet`** — it is a server, nobody switches it
  from a panel, and there is no reason to move a working tunnel on the machine everything
  depends on. Its copy is protected by `modules/wg-unmanaged.nix` instead. The peer key and
  endpoint are now shared `let` bindings so the two implementations cannot drift.
- `modules/family/wg-endpoint.nix`: the `Restart=on-failure` overrides are filtered to
  interfaces `wg-quick` actually builds — without that, sulfur would declare a
  `wg-quick-wgadm` unit with a `serviceConfig` and no `ExecStart`. The roaming script is
  unchanged; it still writes `wg set … endpoint` to the kernel device, and the existing NM
  dispatcher hook re-runs it after any reactivation.
- **Do not edit these connections in the GNOME UI.** Toggling is safe and is the point;
  editing promotes the profile to `/etc` and leaves two competing copies.

### Security (hydrogen's WireGuard hubs were exposed to the same NetworkManager flush)
- **What was missed.** The previous fix derived `networking.networkmanager.unmanaged` from
  `networking.wg-quick.interfaces` only, and lived in `modules/family/wg-endpoint.nix`. hydrogen
  imports neither — it builds `wgadm` and `wgfam` with `networking.wireguard.interfaces`
  (`modules/family/vpn-hub.nix`) — so it kept an empty unmanaged list while running GNOME, and
  therefore NetworkManager, for RustDesk.
- **Why that is the worst case.** A flush on a laptop costs that laptop its tunnel. A flush on
  hydrogen drops both hubs at once: every family device and sulfur lose every service
  simultaneously, with the same silent signature — units still `active`, handshakes still
  reported, no address and no routes.
- **The fix.** New `modules/wg-unmanaged.nix`, imported for every host via `commonModules` in
  `flake.nix`, deriving the unmanaged list from **both** `wg-quick.interfaces` and
  `networking.wireguard.interfaces`. hydrogen now marks `fleet`, `wgadm` and `wgfam`; the four
  family laptops mark `wgfam`; sulfur marks `fleet`, `wg0` and `wgadm`. The `mkMerge` block
  added to `wg-endpoint.nix` is removed again — that module is about endpoint selection, not NM
  ownership.
- hydrogen never roams, which is why it needs no endpoint selection. That is not why it is
  safe: the exposure comes from NM managing the device at all, not from changing networks.

### Fixed (sulfur: NetworkManager was silently gutting the wgadm tunnel)
- **The symptom.** Name resolution failed on sulfur and came back after "turning WireGuard
  off". The tunnel that was toggled was `wgadm`, from GNOME's network panel.
- **Root cause.** NetworkManager has managed WireGuard devices since 1.16, so a tunnel that
  `wg-quick` created still appears as an NM device — and as a toggle in GNOME. Switching it
  off *deactivates* the device: NM flushes the address and every route. `wg-quick-wgadm.service`
  knows nothing about this and stays `active (exited)`.
- **Why it stayed hidden.** The result is a tunnel that looks alive from every angle. The
  unit reads active, and `wg show` reports recent handshakes for both peers — because
  keepalives are sent to the peer's endpoint over the *underlying* default route and never
  need the tunnel's own address. Observed on sulfur 2026-08-09: `wgadm` was `link/none`
  with no `10.41`/`10.42` routes at all, so every service behind it was unreachable while
  nothing logged an error.
- **The fix.** `modules/family/wg-endpoint.nix` now marks every `networking.wg-quick.interfaces`
  entry `unmanaged` in NetworkManager, derived from the attrset so a tunnel added later is
  covered automatically. NM can no longer flush them, and they vanish from the GNOME panel,
  so there is no toggle to hit by mistake. Applies to sulfur (`wg0`, `wgadm`, `fleet`) and
  the four family laptops (`wgfam`), which had the identical latent bug. hydrogen is
  unaffected — it does not run NetworkManager, and its derivation is unchanged.
- **`wg-endpoint` now runs after the tunnels exist.** Its boot run started in the same second
  as `wg-quick`, found no interface, and returned early from every `configure()` call, so the
  endpoint kept its bootstrap LAN literal until the `OnBootSec=2min` timer. Away from home
  that was two minutes of a tunnel dialling `10.0.0.10`.

### Changed (sulfur: wg0 is a manual break-glass tunnel, not a boot-time one)
- `autostart = false`, matching `modules/fleet-vpn.nix`. `wgadm` is the everyday tunnel;
  `wg0` exists to reach the whole home LAN — and hydrogen's sshd on `br0` — when `wgadm` or
  hydrogen's sops decrypt is itself what broke. Recovery access that depends on the thing
  being recovered is not recovery access, so it stays declared.
- Its boot cost was real: the endpoint is a hostname, `wg-quick` resolves it during
  `wg setconf`, and on a boot that beat the Wi-Fi the lookup failed and left the unit dead
  for the session (2026-08-08 and -09; fine on -06 and -07). Started by hand on an
  already-connected machine, that failure mode does not exist, so the retry and dispatcher
  scaffolding added earlier the same day was removed again.

### Fixed (sulfur: Mullvad would have pointed DNS at an unreachable resolver)
- `mullvad dns set custom 10.0.0.1 1.1.1.1` put the home router first in `/etc/resolv.conf`
  on every connect. glibc has no concept of a nameserver being unreachable, only of one being
  slow, so off the home LAN it would try 10.0.0.1 first and eat a 5s timeout per lookup.
  Now `custom 1.1.1.1`.
- **This was not the outage above.** It was found while chasing it and initially blamed for
  it; the daemon log then showed Mullvad never connected on either boot, so the setting was
  never applied. Fixed on its own merits as a latent bug. The rule is worth keeping: a
  resolver whose reachability depends on a tunnel must never be first in `resolv.conf`.
- Cost: the router's ad/tracker filtering is unavailable while Mullvad is connected. The five
  split-horizon names still resolve from `networking.hosts` — `nsswitch` reads `files` before
  `dns` — so local services resolve identically at home, remote, and under Mullvad.

### Security (hydrogen's services are behind WireGuard; the LAN is no longer a credential)
- **What was wrong.** Every service on hydrogen was scoped to `br0`, and the only WireGuard
  hub lived on the router, forwarding to hydrogen's LAN address — so a tunnel peer *was* a
  LAN citizen and the firewall could not tell them apart. Network location was the
  authorisation. `modules/minecraft-server.nix` has always said what that costs: the server
  runs `online-mode=false` and verifies no identity, so anything that can reach 25565 may
  claim to be any child. "Anything" included every device that ever joined the wifi.
- **What replaced it.** Two hubs on hydrogen (`modules/family/vpn-hub.nix`):
  **`wgadm`** (`10.42.0.0/24`, 51822) for sulfur — SSH, RustDesk, Syncthing and the web
  services; **`wgfam`** (`10.41.0.0/24`, 51821) for family devices — `80/443` and `25565`,
  nothing else. `hosts/hydrogen.nix` now opens **no TCP port globally**; the only global
  entries are the two listen ports.
- **Peer isolation is enforced on the hub, not just declared on the client.** A family
  laptop's `allowedIPs` stops it addressing anything but the hub, but that is configuration
  on a machine a child has physical access to. The enforcing half is a dedicated
  `family-forward` chain, jumped to from `FORWARD` position 1: sulfur→laptop port 22,
  established returns, then `-i wgfam -j DROP` and `-o wgfam -j DROP`. No family peer
  reaches the LAN, the router's admin page at 10.0.0.2, or a sibling.
- **Why a chain rather than four rules appended to `FORWARD`.** The first version appended
  them individually, and hydrogen's first switch produced three of the four — `-i wgfam -j
  DROP` was absent. `FORWARD`'s policy is `ACCEPT`, so a partial application is not a
  weaker boundary, it is none: a peer's packet addressed to 10.0.0.2 leaves via `br0`,
  where `-o wgfam -j DROP` cannot match. It also fails silently, and the three rules that
  *did* land make it look healthy. Creating, flushing and refilling one chain makes the
  set all-or-nothing, fixes the order by construction, and survives reloads and libvirtd
  editing the same table.
- `22` stays on `br0` deliberately, and the router hub stays alive as LAN-only access. A bad
  tunnel config or a failed sops decrypt is then recoverable without walking to the machine.
- **Removed 6789/7878/8096/8989** from hydrogen's global firewall — sabnzbd/radarr/jellyfin/
  sonarr ports for `modules/usenet.nix`, which no host has imported in a long time.
- `services.syncthing.openDefaultPorts = false` on hydrogen; 22000/21027 are on `wgadm`
  only. sulfur is the only machine that syncs with it and is a `wgadm` peer, so nothing
  is lost.

### Added (four family laptops)
- `modules/family/profile.nix` — the kids' laptop counterpart to `modules/workstation.nix`:
  GNOME, key-only sshd, NOPASSWD sudo for sheath, `users.mutableUsers = false` with both
  passwords from sops, and a deliberately small package set (VSCodium, LibreOffice, Chrome,
  Firefox, Klavaro, KeePassXC, Nextcloud client, Steam, the pinned Minecraft client).
  It does **not** import `workstation.nix`; the header explains the three reasons.
- `hosts/{gentlemenpupil,vizualwanderer,phantomspecialst,maddreamer}.nix` declare only a
  hostname. Username, WireGuard address, sops key names and Minecraft handle all derive from
  it via `modules/family/peers.nix`.
- **Hostnames are the kids' Minecraft handles, lowercased — not their names.** Usernames and
  hostnames are needed at *evaluation* time, so sops cannot supply them (secrets exist only
  at runtime under `/run/secrets`); the handles were already committed in
  `modules/minecraft-couch.nix`, identify nobody, and keep the login and game identities in
  step. Only real secrets went to sops, keyed by that same name: `wg-priv-<host>` and
  `<host>-password-hash`. An earlier draft numbered them `family-device-1..4` to keep names
  out of a public repo — redundant once the names are handles, and a second identifier to
  keep in step for nothing.
- First use of `sops.secrets.<name>.neededForUsers` in this repo — the only way a declarative
  password can come from sops, since it decrypts before user creation.

### Added (secret scoping, and a `.sops.yaml` at last)
- The repo had **no `.sops.yaml`**: one age key read everything. Putting that key on a child's
  laptop would have handed it the Nextcloud admin password, the Borg repository key and the
  fleet VPN SSH key. There are now two recipients — `main` keeps `secrets/secrets.yaml`,
  `family` additionally reads `secrets/family.yaml` (per-device WireGuard keys and password
  hashes) and nothing else. `install.sh` places the right key per host.
- `gen-family-secrets.sh` generates all of it — eight WireGuard keypairs, the family age key,
  five password hashes — without any plaintext reaching a terminal, argv, or shell history.
  It prints only public keys. Rationale for each contortion is in its header; the short
  version is that `/proc` makes argv world-readable and `shred` cannot overwrite on CoW.

### Added (tunnels that stay up at home)
- `modules/family/wg-endpoint.nix` re-targets a live peer with `wg set ... endpoint` on every
  NetworkManager event and every 5 minutes. At home it uses hydrogen's LAN address, avoiding
  a NAT-hairpin dependency and a pointless round trip to the WAN port; away it uses
  `hub.luckyobserver.com`. It **probes rather than assumes** — plenty of other houses use
  `10.0.0.0/24`, and guessing wrong there would silently leave a child with no tunnel.
- **No manual DNS step, and no manual router step.** The public endpoint is
  `vpn.luckyobserver.com`, which the router's ddclient already keeps pointed at the WAN
  address; the three hubs are told apart by port, not by name. The forwards for
  `51821/udp` and `51822/udp` are declared in the nixrouter repo (`config.nix`
  `portForwards`), not clicked into a web UI.
- **The Kids VLAN needed a pinhole.** The kids' laptops belong on the router's filtered
  Kids VLAN, which drops everything to `10.0.0.0/8` — including the tunnel they need to
  reach hydrogen at all. Falling back to the public endpoint does not help: it arrives at
  our own WAN address from the inside, where `forwardPorts` (`-i wan`) does not match.
  nixrouter `config.nix` `kidsPinholes` opens exactly one UDP port on one host.
- `wg-endpoint.nix` no longer gates the LAN probe on holding a `10.0.0.x` address — the
  laptops never do. It probes unconditionally and lets the handshake decide, and skips
  the probe entirely while the current endpoint is healthy so the 5-minute timer cannot
  disturb a working tunnel.
### Changed (Borg CLI names now say what they mean)
- `borg-local` addressed `/data/borg` specifically, which stopped being "the local one" the
  moment the root SSD repo landed. Now: **`borg-data`** (`/data/borg`), **`borg-rootfs`**
  (`/var/backup/borg`) and **`borg-remote`** (BorgBase) are per-repo wrappers, and
  **`borg-local` runs both on-machine backups** — `/data` then root. "Back up this machine
  locally" became two operations, and remembering the second is exactly what silently does
  not happen.
- `services.borgbackup.jobs.local` → `.data`, so the unit (`borgbackup-job-data`), the CLI
  and the archive prefix (`hydrogen-data-*`) finally agree.
- **The rename needed care, and this is the part worth not rediscovering.** `archiveBaseName`
  defaults to `<hostname>-<jobname>` and `prune.prefix` defaults to `archiveBaseName`, so the
  prune line would have moved from `--glob-archives 'hydrogen-local*'` to `'hydrogen-data*'` —
  silently orphaning all 15 pre-rename archives. Never pruned again: immortal, holding ~191 GiB
  of chunks that could never be freed. `prune.prefix = "hydrogen"` widens the glob so both
  series prune as one timeline and the legacy names age out under 7/16/24. Verified on the
  built config before switching. Borg's files cache is keyed by repository ID, not job name,
  so the rename cost nothing at runtime.
- `borg-local` refuses borg subcommands rather than silently doing something else — `borg-local
  list` now errors with the replacement command named, since it used to work. It refreshes the
  pg_dumps once (both archives get the same snapshot), runs the jobs **sequentially** — they
  read the same spindles and both toggle the Minecraft autosave — and **runs the second even if
  the first fails**, because a failing `/data` is precisely the scenario the root repo exists
  for. Exits non-zero if either failed.
- **Fixed: `BORG_PASSCOMMAND` was an unqualified `cat`.** It resolved against the caller's PATH,
  so the wrappers worked from a login shell and failed anywhere else — found when a `borg check`
  under `systemd-run` died with `[Errno 2] No such file or directory: 'cat'` after the repository
  check had already passed. Minimal environments are exactly where a restore happens. Now
  `${pkgs.coreutils}/bin/cat`. The jobs were never affected; the nixpkgs module gives those
  units a full PATH.

### Added (a third Borg repo, on hydrogen's root SSD)
- **The exposure.** `/data` is btrfs **RAID0** across two USB-attached rotational disks, so
  either member dying takes the array — and the array held two of the three copies of
  everything: the live `/data/immich` media (180 G) *and* the local repo `/data/borg`
  (191 G). A `/data` failure left exactly one copy, offsite, and a 180 G restore over WAN.
- `modules/backup.nix` — `services.borgbackup.jobs.rootfs`, repo `/var/backup/borg`, same
  `backupPaths`, `prune`, `passCommand` and Minecraft flush hooks as the other two. The
  `borg-rootfs` CLI falls out of the existing `mkBorgCli` helper, so `sudo borg-rootfs
  list|check|backup` behaves exactly like `borg-local`.
- **A third job, not an rsync mirror of `/data/borg`.** An independent repo has its own
  chunk index and can be `borg check`ed on its own terms. A mirror would faithfully
  reproduce any damage in the source repo, and would carry the same Repository ID — which
  then collides with the original's cache in `/root/.cache/borg`.
- **04:30, not 03:00.** `local` and `remote` already fire together and already race over the
  Minecraft autosave: each wraps its run in `save-off`/`save-all flush` and re-enables
  saving from `ExecStopPost`, so whichever finishes first turns it back on while the other
  is still archiving. A third concurrent job would widen that window and add a third reader
  to the same two spindles.
- `RequiresMountsFor=/data` is set explicitly: the job writes to root but *reads*
  `/data/immich`, and the nixpkgs module only derives that from the repo path. Without it a
  boot with the array absent runs borg against a missing source, which `failOnWarnings`
  turns into a failed unit for a reason unrelated to its own repo.
- The repo path is deliberately outside `backupPaths` — that list names
  `/var/backup/postgresql`, not `/var/backup`. Widening it would make every job archive the
  backups into themselves; commented at both sites.
- Integrity needs no new unit: `services.btrfs.autoScrub` already scrubs monthly, and btrfs
  scrub is **filesystem-wide, not per-subvolume**, so pointing it at `/persist` covers every
  subvolume on `nvme0n1p2` including `@root`. A one-off `borg check` after the first run
  covers what a scrub cannot (a torn archive).
- **Prerequisite, now cleared:** the 2026-07 silent corruption was bad RAM, since pulled;
  memtest and the deferred `btrfs scrub /data` are both clean as of 2026-08-05. The four
  `corruption_errs` per member are stale counters from that era.
- Space: ~186 G for the first archive (one copy of immich dominates; ~11 G is everything
  else), leaving ~207 G free on root. Immich growth eats that — watch `df -h /`.

### Changed (Prism Launcher replaced by an offline, Nix-pinned client)
- **The problem.** Prism kept everything the game needs to *run* as undeclared state and
  refetched it from Mojang: the client jar, 115 libraries, 424 MiB of assets, a JVM, and
  `accounts.json` — the cached Microsoft account that was the only reason `--offline`
  launching worked at all. `modules/backup.nix` excluded those trees as "re-downloadable",
  and `docs/minecraft.md`'s first setup step was "create the instance by hand in the GUI".
  That is a playable setup only for as long as Mojang keeps serving 1.21.10.
- `packages/minecraft-client/` — the game itself, pinned. `update.sh` generates
  `libraries.json` from Mojang's version manifest (115 library artifacts, the client jar,
  the asset index and the log4j config, each with its sha1 as SRI); `default.nix` assembles
  them, plus a single fixed-output derivation for the 4403 asset objects (424 MiB, one
  hash — the objects are content-addressed upstream, so the tree is bit-identical every
  time), into the directory layout a launcher expects.
- The **Fabric client profile is generated**, not fetched: `meta.fabricmc.net`'s
  `/profile/json` stamps `releaseTime`/`time` at request time, so the same URL returns
  different bytes on every call and there is no hash to pin. Writing it in Nix also means it
  reuses the eight loader jars `packages/fabric-server.nix` already pins, now exposed as
  `passthru.loaderLibs` — one loader bump for both sides.
- `packages/minecraft-client-launcher.nix` — `minecraft-client`, a wrapper around
  `pkgs.portablemc`. portablemc skips any file already present at the expected size
  (`download.py:144-156`), so with the payload complete its download list comes out empty.
  **Verified offline**: an empty game directory inside `unshare -rn` resolves the version,
  4403 assets and 78 libraries and launches, with no cached manifest and no network. Its
  manifest cache lives in the *work* dir (`cli/__init__.py:85`), which is what lets the main
  dir be a read-only store path shared by every player.
- Offline UUIDs are computed the way the game does —
  `UUID.nameUUIDFromBytes("OfflinePlayer:<name>")` — rather than portablemc's private
  `uuid5` namespace. Checked against a reference implementation for five names.
- `modules/minecraft-client.nix` replaces `modules/minecraft-mods.nix`.
  `services.minecraftClient` takes a player name, a server and an archive directory. The
  `minecraft-mods-link.service` oneshot and `packages/minecraft-mods-link.nix` are gone: the
  launcher re-points `mods/` and seeds the mod configs on every launch, which closes the hole
  where an instance created since the last switch stayed silently unlinked.
- **The archive.** `minecraft-archive.service` on hydrogen mirrors the client and server
  closures into a local Nix binary cache at `/var/lib/minecraft-archive` (~1.6 GB, zstd) on
  every switch that changes them, and `modules/backup.nix` sends it to both borg repos. This
  is the copy that makes a restore independent of Mojang, Modrinth and maven.fabricmc.net
  still serving these versions: `nix copy --no-check-sigs --from file://…` plus the flake.
  Not a full offline OS restore — the rest of the system closure still comes from
  cache.nixos.org.
- `modules/minecraft-couch.nix` — `minecraft-couch-sync` deleted along with the four Prism
  data directories it maintained. Those existed only because Prism refuses to run twice from
  one data directory, so each player needed a copy with seven shared trees symlinked back in;
  a CLI launcher is just a process. A player directory is now `options.txt`, `config/`,
  `screenshots/` and a `mods` symlink. The "add a player" path creates the directory itself.
- `hosts/sulfur.nix` — `prismlauncher` dropped; `services.minecraftClient` with a desktop
  entry that connects straight to `10.0.0.10:25565`. Verified end to end on sulfur's NVIDIA +
  Wayland session: all 11 mods load, the window renders, JEI and Controlify initialise.
- `modules/backup.nix` — `~/.local/share/PrismLauncher` and its six exclusions removed;
  `/var/lib/minecraft-archive` added. `backupExclude` is now empty.
- **Migration is manual and one-time** (each player's `options.txt` and `config/`); the worlds
  are server-side and untouched. `docs/minecraft.md` has the commands, and was rewritten — it
  had also gone stale on the Fabric-server change: it still listed Effortless Crafting, still
  claimed the server had no mod loader, and still explained why there was no recipe viewer.

### Fixed (hydrogen journal audit)
- `hardware/hydrogen.nix` — ESP mounted `fmask=0077,dmask=0077` instead of the generated
  `0022`. vfat carries no ownership of its own, so the mask is the ESP's only access control,
  and `systemd-boot-random-seed` was logging `/boot/loader/random-seed` as "a security hole" on
  every boot. Only root reads the ESP from Linux and firmware ignores unix permissions, so the
  tightening costs nothing. Takes effect on remount or reboot.
- `hosts/hydrogen.nix` — added `smartmontools`. Drive health on `/data` was unreadable simply
  because `smartctl` was not installed; that matters on a RAID0 pair where both members carry
  4 btrfs `corruption_errs` and btrfs can detect corruption but never repair it.
- Removed a stale home-manager `sops-nix.service` user unit (runtime, no config change). It
  failed at every login with `cannot read keyfile ~/.config/sops/age/keys.txt` — hydrogen is
  impermanent and has no user-level age key. The gate in `home/sheath.nix` is already correct
  (`sops.secrets` evaluates to `{}` there); the unit was an orphaned symlink into a home-manager
  generation from 2026-07-15 that HM never cleaned up.
- Not fixable, recorded so it is not re-investigated: the ACPI BIOS errors (`_TZ.CHGZ._CRT`,
  `_SB._OSC`) are ZBook firmware bugs, and `bap: BAP requires ISO Socket` is LE Audio only —
  irrelevant to the couch gamepads.

### Changed (the server now runs Fabric)
- The server was deliberately loader-free. Since Minecraft **1.21.2** the recipe list and
  container contents live server-side and are not sent to clients, so two things had no
  client-side answer at all: no recipe viewer works, and crafting from nearby chests could
  only be approximated by a client mod opening each chest behind a held `Ctrl` — a key the
  couch gamepads do not have. Both are fixed by a mod on the server, and only there.
- `packages/fabric-server.nix` — Fabric Loader as a drop-in `services.minecraft-server.package`,
  exposing `bin/minecraft-server` with the same argument contract, so the nixpkgs module's
  declarative `server.properties`, console FIFO and hardening are untouched. Built from the
  launch profile at `meta.fabricmc.net/v2/versions/loader/<mc>/<loader>/server/json`: a main
  class plus 8 hash-pinned jars (4.7 MB), over the vanilla jar from `pkgs.minecraft-server`.
  **Not** the `/server/jar` installer, which downloads the game and its libraries into the
  working directory on first run. Mirrors the vanilla package's runtime env exactly — same
  openjdk 21 headless, same `udev` on `LD_LIBRARY_PATH`.
- Server mods are a **strict subset** of the client list, derived from the same entries via a
  `server = true` flag, so the two can never disagree on a version or hash. Installed into
  `/var/lib/minecraft/mods` from `preStart` with the same delete-then-copy discipline as the
  datapacks.
- **Nearby Crafting** replaces Effortless Crafting: chest contents simply count as inventory,
  with no modifier key, which is what makes it work on a gamepad. Its Modrinth entry lists no
  dependencies; the jar disagrees and the jar wins — `fabric-api`, `recipebookaccess`, `yacl`
  **and** `modmenu` are hard `depends`. Mod Menu is `environment=client`, which looked like it
  would break a dedicated server; it does not — Fabric loads client-env jars on a server as
  dependency candidates. Verified by running the exact set (53 mods, "Done"). `cloth-config`
  and the Effortless Crafting config default go with it.
- **JEI is back**, client and server, and now actually syncs recipes.
- Version lockstep assertion: `fabric-server.nix`'s `mcVersion` must equal
  `pkgs.minecraft-server.version`. Intermediary mappings are per-game-version, so a nightly
  auto-update bumping the jar against stale mappings would fail at runtime in the dark; this
  turns it into an eval error naming both versions.
- **Unverified:** that an unmodded client can still join. It should — no server mod adds
  registry entries (Nearby Crafting is 7 classes and touches no registry; JEI adds no content),
  so Fabric API's registry sync has nothing to synchronise — but this is the guarantee that
  protects every phone and tablet on the tunnel. Test before relying on it.

### Added (chest crafting)
- `packages/minecraft-client-mods.nix` — **Effortless Crafting** (`fabric-1.21.10-v1.3.0`),
  which lets you craft from items in reachable chests without hauling them to the table, plus
  `cloth-config` which backs its Mod Menu settings screen (same reasoning as Mod Menu itself).
  - **Not "Nearby Crafting"**, which is the better-known mod for this and what was asked for:
    it is `server_side: required`, so it cannot work against a vanilla server. Craft From
    Chests is server-required too. Effortless Crafting does the same job entirely client-side
    — verified from the jar rather than the Modrinth metadata, since that field is
    author-declared: its `fabric.mod.json` declares `environment: "client"` (mod id
    `reachcrafting`).

### Removed (paperless-gpt)
- `modules/paperless-gpt.nix` deleted, import dropped from `hosts/hydrogen.nix`,
  `/var/lib/paperless-gpt` removed from `backupPaths`, and the orphaned `paperless-gpt-token`
  removed from `secrets/secrets.yaml`. Not wanted; it was also the only source of errors in
  hydrogen's journal (13 `connection refused` against paperless at boot — it starts before
  paperless is listening despite the soft ordering, since `After=` waits for the unit to start,
  not for the socket).
- **podman leaves hydrogen with it.** `virtualisation.podman.enable` was set by that module and
  nothing else on the server used a container, so the server is back to no container runtime.
- paperless and ollama are untouched. `/var/lib/paperless-gpt` is left on disk — no longer
  backed up, delete by hand if wanted. The pulled image is still in podman's store; it goes
  when podman does, or `podman system prune -a` before the switch.

### Fixed (hydrogen: systemd-logind suspend livelock)
- `hosts/hydrogen.nix` — `systemd-logind` was wedged in a tight retry loop: *"Suspending…"* →
  *"Unit suspend.target is masked, refusing operation."* → *"Permission denied"*, roughly **240
  times a second**, burning **75% of a core**. It had emitted ~7M journal lines in four hours,
  which blew past journald's retention and **evicted the rest of the day — including the 03:00
  backup window**, so the nightly borg run had no diagnosable record. Found while auditing
  whether the Minecraft backup was complete.
  - Not caused by anything asking it to suspend: a `busctl monitor` capture contained **zero**
    messages addressed to `login1`. logind was re-querying `suspend.target`'s `LoadState` from
    PID 1 on its own and never clearing the pending operation. Ruled out on evidence: no input
    events on the Sleep/Power/Lid devices, battery healthy at 97% fully-charged, `gsd-power` at
    0.0% CPU, `sleep-inactive-{ac,battery}-type` both `'nothing'`.
  - The four masked sleep targets are what turn a refusal into a livelock, but they **stay** —
    an unnoticed suspend would take Minecraft, Nextcloud, Immich, Paperless and the backups
    offline at once, which is worse than a failed attempt. The fix instead stops logind from
    ever initiating one: `SleepOperation=` (empty, systemd ≥256) leaves it no candidate
    operation, and `HandleSuspendKey`/`HandleHibernateKey` (+ LongPress) block a stray event.
  - **A switch does not apply this.** NixOS sets `restartIfChanged = false` on
    `systemd-logind` because restarting it breaks X11, so the new `logind.conf` is written but
    not loaded until `systemctl reload systemd-logind` (or a reboot).

### Added
- `modules/backup.nix` — the couch Minecraft client state is now backed up:
  `~/.local/share/minecraft-couch` (roster + each player's `options.txt` and Controlify
  bindings) and `~/.local/share/PrismLauncher` (canonical instance + `accounts.json`). These
  are the only paths under `/home` in `backupPaths`. The world is server-side and already
  covered, so this is about state the flake cannot rebuild, not about characters or builds.
  Prism's `assets`/`libraries`/`meta`/`java`/`cache` are excluded — ~1 GB it refetches anyway.
  - Both directories are pre-created via `systemd.tmpfiles`, because the jobs run with
    `failOnWarnings = true` and borg exits 1 on a missing source path — on hydrogen, where
    Prism has never been opened, adding these paths would otherwise have failed the **entire**
    nightly backup, Nextcloud and Immich included.

### Added
- `minecraft-mods-link.service` — re-links the configured Prism instances on boot and on any
  switch that changes the jar set. The store path is baked into `ExecStart`, so a changed mod
  list changes the unit and `switch-to-configuration` restarts it; previously a rebuild that
  added a mod left both machines silently stale until someone remembered the command.
  `Type=oneshot` + `RemainAfterExit` so it counts as active and therefore gets restarted;
  runs as `sheath` rather than root, since everything it touches is under that user's home.
  Instances are named per host via `services.minecraftClientMods.instances`.
  - `minecraft-mods-link` gained `--if-present` (a missing instance is a skip, not an error —
    hydrogen's `couch` does not exist yet and must not fail the switch) and an idempotence
    check that exits early when the link is already correct, so the boot-time run is silent
    and an unrelated switch does not churn `rm`/`ln` on the user's instance.
  - Does **not** cover creating a new instance under an otherwise unchanged configuration —
    nothing changed, so nothing restarts. One manual run, or `systemctl restart`.

### Fixed
- `packages/minecraft-mods-link.nix`, `modules/minecraft-couch.nix` — both hardcoded
  `.minecraft` as the Prism game root. **Prism 11 uses a plain `minecraft/`**; the dotted name
  is the MultiMC-era layout, kept only for inherited instances. The symptom was an empty Mods
  tab: the link landed in a directory Prism never reads, and a stray `.minecraft/` was left
  beside the real game root. In `minecraft-couch-sync` the same bug was worse but latent — the
  rsync excludes would have matched nothing, flattening each child's `options.txt`, `config/`
  and saves on every sync. Both now resolve the game root at runtime the way Prism does.
  Nothing caught this earlier because no Prism instance existed when the code was written.

### Added (Minecraft mods: declarative client jars + Vanilla Tweaks datapacks)
- `packages/minecraft-client-mods.nix` — eight pinned Modrinth jars for Fabric 1.21.10, built
  into a `linkFarm`. Requested: **Xaero's Minimap**, **Better Name Visibility**, **Jade**.
  Supporting: `fabric-api`, `yacl`, `modmenu` (vanilla's menu has no entry point for a YACL
  screen, so without it Controlify and Better Name Visibility are config-file-only). **Sodium
  and Controlify moved out of the Prism GUI into this list** — they were manual setup steps
  that were easy to get wrong.
  - **No recipe viewer, deliberately.** EMI was requested; since Minecraft **1.21.2** the
    recipe list lives on the server and is no longer sent to clients, so no client-only viewer
    can enumerate recipes against a vanilla server. JEI was shipped first and reported exactly
    that in chat on every join. EMI never shipped past `1.1.24+1.21.1`, i.e. it stops right
    before the change. REI's client-side fallback breaks for any recipe unlocked in-game
    (shedaniel/RoughlyEnoughItems#2063), and Unlock All Recipes unlocks all of them; the fix
    (#2065) merged 2026-07-29 and is unreleased on every branch. Unlock All Recipes leaves the
    vanilla recipe book complete, so what is actually lost is reverse lookup and the brewing
    and smithing stations. Revisit when a REI build published after 2026-07-29 supports the
    server's version.
  - Rejected: **Fabric + JEI on the server** (JEI needs Fabric API server-side, and the
    unmodded-join guarantee would need re-verifying) and **downgrading to 1.21.1** (no world
    downgrade path from `DataVersion` 4556, and 1.21.1's server jar was verified to lack
    `pause-when-empty-seconds` — the only reason this always-on server idles at 0.10% of a
    core rather than ticking continuously).
- `packages/minecraft-mods-link.nix` + `modules/minecraft-mods.nix` — `minecraft-mods-link
  <instance>` points a Prism instance's mods folder at the store path; imported by both
  hydrogen and sulfur so **one list drives both machines and they cannot drift**.
  `minecraft-couch-sync` calls it on every run, so a rebuild reaches all five couch players
  without a second step. A pre-existing non-empty `mods/` is stashed to `mods.stateful` once
  rather than deleted, matching the convention the nixpkgs minecraft-server module uses for
  `server.properties`. **Consequence, deliberate: Prism's GUI can no longer install mods.**
  - Guarded by an assertion that `pkgs.minecraft-server.version` equals the pinned
    `mcVersion`. Without it, a nixpkgs bump past 1.21.10 builds fine and the symptom is four
    children staring at an incompatible-mod screen.
- `packages/minecraft-datapacks{,.nix}` — **CoordinatesHUD**, **Unlock All Recipes**, **Graves**
  and **Multiplayer Sleep** (Vanilla Tweaks), installed into `world/datapacks` from
  `minecraft-server.nix`'s `preStart`. Datapacks are vanilla data, not mods: no loader on the
  server, so the "a phone joining over the tunnel installs nothing" guarantee is untouched.
  - **The zips are vendored** (~146 KB) because vanillatweaks.net builds a bundle per request
    and returns a single-use URL — POSTing the identical selection twice gave
    `VanillaTweaks_d377131_UNZIP_ME.zip` then `…d860034…`. There is nothing stable for
    `fetchurl` to pin, and a link that 404s later would break the nightly auto-update.
  - Delete-then-copy, not just copy, so dropping a pack from Nix removes it from the world;
    the `vt-` prefix bounds what will be deleted, so a hand-dropped pack is untouched.
  - **Copied, not symlinked.** Since 1.19.4 Minecraft refuses to follow symlinks inside a world
    directory unless they are in `allowed_symlinks.txt`, so the obvious `systemd.tmpfiles`
    `L+` approach would have produced a world with silently zero datapacks.

### Changed (couch Minecraft: a pre-launcher instead of pinned controllers)
- `modules/minecraft-couch.nix` — identity was a property of the HARDWARE: a udev rule keyed
  each seat to a controller's Bluetooth MAC, so picking up a sibling's pad logged you in as
  your sibling, the "2 Players" icon always launched seats 1 and 2 (the third and fourth
  child's pads did nothing), and four MACs had to be collected by hand before anything worked
  at all — they were still `00:00:00:00:00:00`, so `/dev/input/p1..p4` never appeared.
  Replaced with `minecraft-couch-menu`, a pre-launcher that asks who is holding each pad.
  The question the MAC answered — *which event node is seat N's?* — is now never asked.
  - Four MAC-keyed udev rules collapse to one:
    `SUBSYSTEM=="input", ENV{ID_INPUT_JOYSTICK}=="1", SYMLINK+="input/couchpad-%k"`.
    The `ID_INPUT_JOYSTICK` filter is kept — pads expose extra nodes for motion sensors and
    force feedback that must not be offered as controllers.
  - **The roster is runtime state**, `~/.local/share/minecraft-couch/players.json`, seeded once
    from `seedPlayers` and authoritative thereafter (documented footgun: editing the Nix list
    later does nothing; delete the JSON to re-seed). Add/remove players from the couch, no
    rebuild. Seeded with the four kids plus `LuckyObserver`, so sheath can play from the couch
    or from sulfur. Data dirs re-key from `p<index>` to `<name>` so client settings follow the
    child, not the seat — free to do now, since nothing stateful existed yet.
  - **Pairing moved in-app** because it had to: the couch session is Hyprland on tty7 with GNOME
    inactive, so GNOME's Bluetooth panel is unreachable from it. BlueZ allows this without root
    (`<policy context="default"><allow send_destination="org.bluez"/></policy>`).
  - **Keyboard and gamepad drive every screen.** That resolves the chicken-and-egg: with no pad
    paired there would otherwise be no way to reach the pairing screen. hydrogen has a wired
    Dell KB216.
  - Gamepad input is deliberately permissive, because `hid-nintendo` (3× Switch Pro) and
    `xpadneo` (Xbox Elite) disagree on D-pad reporting — hat axis `ABS_HAT0X/Y` vs discrete
    `BTN_DPAD_*`, varying by driver version. All of those move the cursor and any *other* button
    confirms, so only two gamepad actions must work; there is no back button, every screen
    carries a `Back` entry instead. `--probe` dumps raw events to check a new pad against real
    hardware.
  - Count plumbing collapses: four "N Players" icons → one **Minecraft (Couch)**,
    `minecraft-couch@<count>.service` → plain `minecraft-couch.service`, and `COUCH_PLAYERS` is
    gone. The `PAMName`/`TTYPath` pair, VT stash/restore and `Restart=no` are untouched.
  - `minecraft-couch-sync` now loops the roster (or named players) rather than `p1..pN`.
  - Menu is `pkgs.writers.writePython3Bin`, so flake8 runs at build time — it caught four style
    errors before anything was deployed. Driven headlessly through a pty to verify navigation,
    roster seeding, name validation (too-short and duplicate) and the sync-failure path.
  - Known limitations, stated rather than half-built: no late join (a kid arriving after the
    assignment screen needs a session restart), and one login per username.

### Changed (Veloren server disabled)
- `hosts/hydrogen.nix` — `modules/veloren-server.nix` import commented out, and 14004/tcp +
  14006/udp closed with it. **Veloren's rtsim never idles.** Measured on hydrogen with zero
  players connected: **20.7% of a core, continuously** (steady over two windows, 41 threads),
  driven by the 1867 rtsim NPCs across 196 sites and 16 factions that keep simulating whether
  or not anyone is watching. That is by design upstream and there is no equivalent of
  Minecraft's `pause-when-empty-seconds` — the Minecraft server measured **0.10%** idle under
  the same conditions, since 1.21.2+ defaults that setting to 60.
  Nobody is playing it, so a permanent ~0.2 cores + ~700 MiB on a 24/7 box is not worth it.
  `modules/veloren-server.nix`, `docs/veloren.md` and `/var/lib/veloren` are all left intact;
  re-enabling is uncommenting the import and the two ports. The world is reproducible from the
  pinned `world_seed` regardless.
  The `veloren` client stays installed on hydrogen and sulfur — it has a singleplayer mode and
  costs nothing at runtime.

### Added (Veloren server on hydrogen)
- `modules/veloren-server.nix` — a persistent Veloren (open-source voxel RPG) server as a
  system service, alongside the existing Minecraft one. **nixpkgs has no `services.veloren`**,
  only `pkgs.veloren` 0.17.0 — one derivation shipping both `veloren-server-cli` and
  `veloren-voxygen` — so the unit is hand-written. Cached on hydra, so this is a 301 MiB fetch
  and not a Rust build. Documented in `docs/veloren.md`.
  - Same security posture as Minecraft, for the same reason: `auth_server_address: None` (no
    veloren.net accounts for the household) means no identity verification, so reachability is
    the authentication boundary. 14004/tcp + 14006/udp are scoped to `br0` in
    `hosts/hydrogen.nix` — LAN and WireGuard peers only, never the internet.
  - **`world_seed` is the world.** Veloren does not store terrain; it regenerates it from the
    seed on every start (~6 s) and `saves/` holds only player diffs plus the character SQLite
    DB. Changing the seed replaces the world and orphans every player-made change. Pinned to
    `20260803` with that warning in the module, the doc, and the changelog.
  - `settings.ron` is declarative via `ExecStartPre` reinstalling it from the store each start
    (the `services.minecraft-server.declarative = true` contract). A **copy, not a store
    symlink**, which would break if a future version wrote the file back. Verified against
    0.17.0 that the server reads and does not rewrite it, and that a *partial* RON is accepted
    with unset fields defaulted — so only the values that matter are named.
  - `VELOREN_USERDATA=/var/lib/veloren` overrides the compiled-in
    `VELOREN_USERDATA_STRATEGY=system`, which would otherwise put state in the service user's
    XDG data dir. Verified it wins at runtime. Static system user rather than `DynamicUser`,
    which would relocate state behind `/var/lib/private/` and complicate the borg path.
  - `--non-interactive` is mandatory under systemd — without it the server reads stdin and the
    terminal driver sends it SIGTTIN.
  - `max_view_distance: Some(30)` against an upstream default of 65: it is the dominant lever
    on server CPU (as `view-distance` is for Minecraft) and this box also runs Minecraft,
    immich and ollama on one 6c/12t Xeon E-2176M. Measured footprint: ~925 MiB peak RSS.
- `pkgs.veloren` added to `hosts/hydrogen.nix` and `hosts/sulfur.nix` systemPackages.
  **Version lock-step is the reason**: Veloren refuses cross-version connections, and client
  and server are the same derivation, so both must come from one flake pin. Airshipper is not
  a substitute — it self-updates to upstream *weekly nightlies*; nixpkgs' `airshipper` is
  0.16.0 and no better. A `flake.lock` bump that moves `pkgs.veloren` is a flag day.
- `modules/backup.nix` — `/var/lib/veloren` added to `backupPaths`. Unlike Minecraft there is
  no console FIFO to checkpoint, so borg can catch `saves/db.sqlite` mid-write; left alone
  rather than wrapped in a stop/start dance, since the world is not in the backup at all and
  the only exposure is a torn character DB.

### Added (contained RE agents)
- `packages/re-container.nix` + `modules/re-container.nix` — `cqwen` and `copencode` run the
  RE agents inside a rootless Podman sandbox, modelled on `cclaude` (flake input
  `github:seandheath/cclaude`), whose security flags are reused wholesale. Only the current
  directory is writable; `$HOME`, the NixOS config and the sops store are unreachable.
  Host `qwen`/`opencode` stay installed as an uncontained fallback. `modules/virtualisation.nix`
  already provides rootless podman and sheath's subUid/subGid ranges, so no new
  virtualisation config was needed.
  - **Reaching ReVa needed `--network=pasta:-T,8080`.** ReVa binds loopback only
    (`[::ffff:127.0.0.1]:8080`), so a container on default networking cannot see it —
    `host.containers.internal` is pasta's gateway (169.254.1.2) where 8080 is unreachable,
    and `--map-guest-addr` did not help. pasta's `-T` forwards the *container's*
    localhost:8080 to the *host's*. Measured from inside: host 8080 reachable, host 8384
    (syncthing) and 631 (cups) blocked, outbound 443 and DNS to the vLLM endpoint fine.
    `--network=host` also works but exposes every host-local service; rejected. Because the
    container's own localhost is what forwards, `httpUrl = http://localhost:8080/mcp/message`
    works verbatim — no container-specific config.
  - Image built with `dockerTools.buildLayeredImage`, not a `Containerfile`. cclaude builds
    from debian + a curl-to-bash installer because that is how Claude Code ships; both agents
    here are already Nix packages, so building from them is reproducible, needs no network at
    build time, and reuses the pinned `packages/qwen-code.nix`. Contents are minimal by
    design — a rogue agent can execute only what is in the image. `python3` is in it as a
    **requirement**, not a convenience: `prompts/re-agent.md` routes all hex/bitwise/sign
    work through `python3 -c`, and both clients pre-approve exactly that form.
  - Divergences from cclaude, all deliberate: no `/nix/store` mount and no nix daemon socket
    (keeps the executable surface to the image); no SSH agent forwarding (an RE agent has no
    reason to hold a credential that authenticates as you).
  - **Secrets go in as environment variables, never as a mounted file**, so nothing secret
    lands in the persistent home volume. A tmpfs `$HOME` was tried first to make it moot and
    abandoned — podman's `--tmpfs` rejects `uid=`, so the tmpfs lands owned by the namespace
    root and the uid-1000 agent cannot write to it. Named volume with `,U` instead, as
    cclaude does. qwen-code resolves settings.json's `$OPENWEBUI_*` placeholders from the
    process environment exactly as it would from a `.env` file.
  - OpenCode's `opencode.json` is rendered with `{file:$HOME/.config/opencode/re-instructions.md}`
    baked in as an **absolute host path**, which OpenCode resolves literally — config load
    fails outright unless that path exists. The prompt is therefore mounted at the host path
    inside the container; it is the one host-shaped path in there, a single read-only file.
- **All 88 ReVa tools are auto-approved in both clients, and this is intentional.** Probed by
  having each agent attempt a real `delete-structure`: both dispatched it with no
  confirmation. This includes all 14 write tools (`set-comment`, `set-decompilation-comment`,
  `set-bookmark`, `create-label`, `create-function`, `set-function-prototype`,
  `rename-variables`, `apply-data-type`, `apply-structure`, `delete-structure`,
  `write-script`, `diff-*`). Note that MCP is a **different code path from the shell tool** —
  the narrow `python3 -c` allow-rules genuinely gate bash and do nothing for ReVa. Sean's
  call (2026-07-30): unrestricted ReVa is the point of the tool. Consequences: the container
  does not protect the Ghidra database at all, and the only remaining control is procedural,
  so `prompts/re-agent.md`'s write-operations section now states plainly that nothing will
  stop the agent and that opening a copy of the project is the analyst's responsibility.
  Both clients *can* gate it if revisited — qwen-code builds rule names as
  `mcp__<server>__<tool>`; OpenCode's permission schema is `.catchall(PermissionRule)` with
  ReVa's tools named `reva_<tool>` — and both syntaxes are recorded in the module.

### Changed (agentic reverse engineering)
- `prompts/re-agent.md` — the RE agent instructions are now a **single canonical file**,
  deployed verbatim to both clients (`~/.config/opencode/re-instructions.md` via
  `modules/opencode.nix`, `~/.qwen/QWEN.md` via `modules/qwen-code.nix`). Both modules
  previously inlined their own copy with a comment asking future-us to keep them in step;
  they had already drifted in two places within one session. No per-client templating was
  needed — the only client-specific bit was a reference to the shell tool by name, which
  the canonical text now avoids (OpenCode calls it `bash`, qwen-code
  `run_shell_command`), so this is a plain shared file rather than a Nix function.
- **Corrected a wrong claim in those instructions.** They asserted there is never a source
  tree — but sessions are sometimes started inside source that is *representative* of the
  binary (upstream project, SDK, vendor drop, a different version), deliberately provided
  as a hint. New "Reference source" section: use it for names, struct/enum layouts,
  constants and algorithm shape; do not trust it for anything checkable in the binary,
  because the version may differ, the compiler rewrites structure (inlining, unrolling,
  layout), and build config may exclude whole branches. Form the hypothesis from source,
  confirm against the binary, attribute which is which, and when they disagree the binary
  wins. Also folded into the context-budget rule (grepping source is much cheaper than
  decompiling to get your bearings) and the write-operations rule (source is the best
  source of names, but rename only on matched evidence — a wrong name gets believed later).
- **Expanded the arithmetic section beyond hex addition.** It previously named only address
  offsets, page boundaries, struct field offsets and hex/decimal conversion, which a model
  will not read as covering "is bit 12 set". Now also covers masks and flag tests, shifts
  and rotates, signed/unsigned reinterpretation and sign extension, endianness swaps, and
  float/int bit reinterpretation, with a verified worked `python3 -c` one-liner for each of
  the ones that are easiest to fake convincingly. The rationale is stated: these are *more*
  dangerous than a wrong sum, because a bad sum yields an obviously out-of-range address
  while a bad sign extension or byte swap yields a plausible value that survives review.
- No permission changes were needed for the above. Both clients' existing `python3 -c *`
  rules already admit multi-statement forms — a semicolon inside the quoted `-c` argument
  does not split the command for rule matching, so `python3 -c 'import struct; …'` runs
  unprompted on both. Control-tested on OpenCode (a bare `touch` under `opencode run` does
  block), so this is genuinely the rule matching and not non-interactive auto-approval.

### Added (agentic reverse engineering)
- `packages/qwen-code.nix` + `modules/qwen-code.nix` — qwen-code as a **second** RE client
  alongside OpenCode, pointed at the same vLLM endpoint and the same ReVa MCP server, so the
  two agent loops can be compared on one binary. Imported from `modules/workstation.nix`.
  Unlike the OpenCode install (a general coding tool with a dedicated `re` agent), this one
  is RE-only: `~/.qwen` carries ReVa and the RE instructions, so every `qwen` session is an
  RE session.
  - **Packaged locally rather than using `pkgs.qwen-code`.** nixos-25.11 pins **0.2.2**;
    upstream stable is **0.21.1**. Not a cosmetic gap — 0.2.2 predates the entire
    `modelProviders` / `providerProtocol` / `permissions` / `context.fileName` schema and
    only supports the old `OPENAI_BASE_URL` env-var auth, so none of the config below works
    on it. Drop `packages/qwen-code.nix` once nixpkgs catches up.
  - Built from the **npm registry tarball**, not `buildNpmPackage` on the GitHub source:
    the published package is fully pre-bundled by upstream's esbuild step — zero runtime
    dependencies, no native `.node` modules, and a vendored **static-pie** ripgrep that
    needs no patchelf. There is nothing for npm to resolve, so `buildNpmPackage` would only
    add an `npmDepsHash` to churn (nixpkgs' own expression additionally has to patch
    node-pty/keytar out of the lockfile). Plain unpack + `makeWrapper` over `nodejs_22`
    (`engines.node >= 22`).
  - **Secrets live in `~/.qwen/.env`, not in `settings.json`** — the opposite of the
    `opencode.json` / `pi-models.json` pattern, for a concrete reason: qwen-code rewrites
    its own `settings.json` on startup (schema migration, `$version` stamp), and that write
    **replaces the sops symlink with a plain 0644 regular file**. Templating the API key
    into it would copy the key out of the 0400 tmpfs sops store into a world-readable file
    in `$HOME` on first run. `settings.json` therefore ships secret-free with `$VAR`
    placeholders; only `.env` (which qwen-code reads and never writes) comes from sops. The
    rewrite was verified to leave the placeholders unresolved.
  - **The published settings docs are wrong about providers.** `modelProviders.<id>` is a
    bare *array* of model entries — the documented `{ protocol, models }` wrapper is
    silently dropped on migration — and the SDK protocol comes from a separate top-level
    `providerProtocol` map. Without that map the models are ignored ("not a built-in
    protocol"). `generationConfig` likewise belongs on the model entry; under top-level
    `model` it is accepted and ignored with a warning.
  - MCP transport is selected by **key name**: `httpUrl` → streamable HTTP, `url` → SSE.
    ReVa serves streamable HTTP, so `httpUrl` is required.
  - Permission rule is `run_shell_command(python3 -c *)`. qwen-code's own schema
    documentation advertises `"Bash(git *)"` and its alias table maps `Bash` →
    `run_shell_command`, but **rules written as `Bash(...)` do not match** in 0.21.1's
    approval path — both the bare and parenthesised forms still prompt. Scoping was
    confirmed: `touch` still prompts under this rule.
  - RE constraints go in `~/.qwen/QWEN.md`, the global context file, which qwen-code
    *appends* to its core system prompt. `QWEN_SYSTEM_MD` was rejected: it replaces the base
    prompt wholesale and would discard qwen-code's own tool-usage scaffolding.
- `modules/opencode.nix` — OpenCode on all workstations, wired to the remote vLLM and to
  Ghidra's ReVa MCP server. Completes the client half of the ReVa + OpenCode + vLLM stack
  whose server half (`packages/ghidra-reva.nix`) landed 2026-07-29. Imported from
  `modules/workstation.nix`, which is also the host gate — hydrogen never evaluates it, so
  unlike `home/sheath.nix`'s `enablePi` there is no hostname test to keep in sync.
  - `~/.config/opencode/opencode.json` is a **sops template**, not an `xdg.configFile`: the
    base URL, served model id and token are all secrets, and `sops.templates` renders whole
    files. Same shape as the `pi-models.json` template. The model id is used as a dynamic
    Nix attribute name so the secret can be a JSON *key*.
  - Provider `vllm` uses `npm = "@ai-sdk/openai-compatible"`, which is already inside the
    nixpkgs `opencode` closure (`lib/opencode/node_modules/.bun`), so it resolves offline —
    no bun fetch on first run.
  - `agent.re` (`mode = "primary"`, so `opencode --agent re`) takes its system prompt from
    `~/.config/opencode/re-instructions.md` via `{file:…}`. Deliberately **not** named
    `AGENTS.md`, which OpenCode auto-loads into every session — the RE constraints (never
    bulk-decompile, ReVa writes to the live program) are noise outside RE work, and would
    otherwise be included twice.
  - MCP URL is `http://localhost:8080/mcp/message`, not the `/mcp` the upstream spec's
    example shows. ReVa 7.3.0 serves at `/mcp/message`; it only responds while Ghidra has a
    program open.
  - The RE prompt forbids mental hex arithmetic and points at `python3 -c 'print(hex(…))'`
    instead, with `agent.re.permission.bash` pre-approving exactly `python3 -c *` so that
    advice isn't blocked by a confirmation prompt. ReVa exposes 88 tools and **none** of
    them is a calculator; its `run-script` tool requires a PyGhidra launch and so always
    fails on this package. The prompt also lists the ReVa tools that remove the need for
    arithmetic entirely (`get-structure-info` for field offsets, `analyze-vtable` for
    slots, `find-cross-references` for branch targets, `get-memory-blocks` for the image
    base).
- **vLLM is deliberately not a NixOS service in this flake, and cannot become one.** The
  only always-on GPU box is hydrogen, whose Quadro P4200 is Pascal (SM 6.1); vLLM requires
  compute capability >= 7.0 (vllm-project/vllm#1431, #963 — still enforced on mainline as of
  2026-06), and nixos-25.11 ships no `services.vllm`. Inference stays remote.

### Fixed (remote model limits)
- `home/sheath.nix`: pi's `contextWindow` was a guessed 32768; the endpoint advertises
  `max_model_len = 262144` (`GET /models`, verified 2026-07-30). Both that file and
  `modules/opencode.nix` now state 262144 / 32768 output for the same endpoint — keep them
  in step. Output is a client-side reservation out of the same window, not a server limit:
  vLLM only enforces `max_tokens <= max_model_len` (262000 accepted, 300000 rejected).

### Changed (host rename)
- `sulphur` is now `sulfur` everywhere: flake attribute, `hosts/sulfur.nix`,
  `hardware/sulfur.nix`, `networking.hostName`, and the sops keys `wg-pub-sulphur` /
  `wg-priv-sulphur` → `wg-pub-sulfur` / `wg-priv-sulfur` (re-encrypted in place with
  `EDITOR="sed -i …" sops secrets/secrets.yaml`; values verified unchanged). The flake
  attribute and `networking.hostName` must stay equal — `modules/auto-update.nix` builds
  `path:~/nixos/#${config.networking.hostName}`. Dated entries below keep the old spelling.
  Outside the repo the router's DHCP/DNS reservation still says `sulphur`, and mDNS is now
  `sulfur.local`.

### Changed (terminal)
- kitty → Ptyxis. `home/ptyxis.nix` replaces `home/kitty.nix`. The home-manager ptyxis module
  only installs the package (and palettes), so what kitty kept in `kitty.conf` — B612 Mono 11
  and `bash --login` — is now GSettings in `modules/dconf.nix`: `org.gnome.Ptyxis`
  (`font-name`, `use-system-font = false`, a pinned default profile UUID) plus that profile's
  `login-shell = true`. `pkgs.b612` is installed explicitly since nothing pulls it in anymore.
  `<Alt>Return` spawns ptyxis. These land as dconf *defaults*, so Ptyxis' own preferences win.

### Added (reverse engineering)
- sulphur: Ghidra 12.1 with the ReVa MCP server extension. `packages/ghidra-reva.nix` —
  an `overrideAttrs` on nixpkgs `ghidra-bin` (a plain fetchzip of the NSA release build)
  bumping 11.4.2 → 12.1 and unpacking ReVa v7.3.0's prebuilt extension zip into
  `Ghidra/Extensions/`. ReVa requires Ghidra >= 12.0, which nixos-25.11 does not have in
  either `ghidra` or `ghidra-bin`. `modules/packages-desktop.nix` swaps `ghidra` for it;
  the derivation still provides `bin/ghidra` and `bin/ghidra-analyzeHeadless`.
  ReVa serves MCP on `http://localhost:8080/mcp/message` and is registered at **user scope**
  in `~/.claude.json` (`claude mcp add --scope user --transport http ReVa ...`), not declared
  in nix — see `modules/workstation.nix` for why. Ghidra-side plugin activation is GUI state
  in `~/.config/ghidra` and remains a one-time manual step.

### Added (minecraft)
- hydrogen: persistent vanilla Minecraft server. `modules/minecraft-server.nix` —
  `services.minecraft-server` declarative, 1.21.10, world at `/var/lib/minecraft`, 6 GB
  heap with a bounded G1 pause target. `online-mode=false` (couch clients are offline
  accounts) with `enforce-secure-profile=false` alongside it, which is required or
  unauthenticated clients are kicked on their first chat message. `openFirewall = false`;
  25565 is instead added to the existing `networking.firewall.interfaces."br0"` list in
  `hosts/hydrogen.nix`. NB: there is **no wg0 on hydrogen** — the WireGuard hub is on the
  router (`vpn.luckyobserver.com`, tunnel 10.40.0.0/24) and peers route to hydrogen's LAN
  address, so tunnel traffic ingresses on `br0` like LAN traffic and one rule covers both;
  the router forwards only 51820/udp, so 25565 stays closed from the internet.
- hydrogen: 1–4 player couch split-screen. `modules/minecraft-couch.nix` provides four
  generated `.desktop` entries ("Minecraft — N Player(s)") → `minecraft-couch N` →
  `minecraft-couch@N.service`, a **real logind session on tty7** (`PAMName=login` +
  `TTYPath`, with `chvt` in `ExecStartPre`/`ExecStopPost`) running Hyprland with a
  generated config. Not a nested compositor: GNOME must keep running for RustDesk capture,
  and Mutter can neither tile into quadrants nor fullscreen a nested compositor's window.
  Window placement is explicit via `hyprctl` by address rather than dwindle, which would
  otherwise give "left half + three stacked" for four clients; geometry is read from
  `hyprctl monitors`, so no 1080p assumption. Each client runs under bubblewrap with a
  tmpfs over `/dev/input` and only its own pad's *resolved* event node bound back in —
  otherwise every client sees every pad and all four characters move in unison. Stable
  player identity via MAC-keyed udev rules (`ATTRS{uniq}` + `ENV{ID_INPUT_JOYSTICK}`);
  `services.joycond` stays off because its virtual uinput devices have no `uniq`.
  Placeholder MACs produce a build *warning*, not an assertion, so the server half
  deploys while controllers are being paired. Four Prism data dirs (`--dir`) because Prism's
  single-instance lock is keyed on the data path — a second `--launch` would otherwise be
  handled by the first process and escape its sandbox; `minecraft-couch-sync` symlinks the
  shared trees and the mods folder so mods are still installed once, in the GUI.
  Also pulls in `modules/bluetooth.nix` (hydrogen had no Bluetooth stack) and
  `hardware.xpadneo.enable` for the Xbox Elite pad. Runbook: `docs/minecraft.md`.
- `modules/backup.nix`: `/var/lib/minecraft` added to `backupPaths`; both borg jobs now
  `save-off`/`save-all flush` through `/run/minecraft-server.stdin` before archiving, with
  `save-on` in `ExecStopPost` (not `postHook`, which is skipped when borg fails and would
  leave autosave off until the next server restart).

### Changed (minecraft)
- hydrogen: `powerManagement.cpuFreqGovernor = "performance"` (HWP's balanced EPP leaves
  frames on the table under sustained load), lid switch ignored in all three
  `HandleLidSwitch*` settings, `hardware.graphics.enable32Bit = true`.
- hydrogen: `hardware.nvidia.package` pinned explicitly to the `production` branch. Every
  branch in the current pin is already 580.142, so this is a no-op today; its job is to
  stop the nightly `auto-update` from moving this Pascal card (GP104GLM, EOL after R580)
  onto a 590 branch that does not support it. Revisit at the next release bump.
- `users/sheath.nix`: added `input` to `extraGroups` (evdev access for the couch clients).

### Added
- hydrogen: self-hosted services — Nextcloud (`nc.luckyobserver.com`), Immich
  (`immich.luckyobserver.com`), calibre-web (`calibre.luckyobserver.com`), paperless-ngx
  (`paper.luckyobserver.com`), all reverse-proxied by nginx and reachable only over
  WireGuard/LAN. New modules: `modules/{nextcloud,immich,calibre,paperless}.nix`.
- hydrogen wired into `flake.nix` `nixosConfigurations` (was previously absent).
- `modules/reverse-proxy.nix`: wildcard `*.luckyobserver.com` TLS via Cloudflare ACME DNS-01
  (`acme-dns-credentials` sops secret); per-service vhosts attach via `useACMEHost`.

### Changed
- hydrogen: 25.11 compatibility fixes — removed deprecated `sound.enable`, renamed
  `hardware.opengl` → `hardware.graphics`, set required `hardware.nvidia.open = false`,
  dropped removed `thefuck` package.

### Added
- hydrogen: local LLM document classification for paperless. `modules/ollama.nix` runs
  ollama on loopback (`127.0.0.1:11434`, no vhost/firewall port) serving `qwen2.5:7b`;
  `modules/paperless-gpt.nix` runs `icereed/paperless-gpt` v0.27.0 as a pinned podman
  container (hydrogen's first container host) that watches paperless for the
  `paperless-gpt-auto` tag and writes back an LLM title/tags/correspondent/document-type.
  The container uses host networking to reach paperless and ollama on loopback; its own UI
  is bound to `127.0.0.1:8080`. API token in sops (`paperless-gpt-token`); `CREATE_NEW_TAGS`
  starts `false` so the model can only assign existing tags. `/var/lib/paperless-gpt` added
  to borg. NB: the P4200 is Pascal (sm_61), which is a non-default CUDA 12.8 gencode target,
  so `nixpkgs.config.cudaCapabilities = [ "6.1" ]` forces a from-source `ollama-cuda` build
  -- without it ollama silently ran on CPU (`total_vram="0 B"`). GPU inference measured at
  ~33 tok/s. This means every future nixpkgs ollama bump recompiles from source (~10 min).

### Fixed
- hydrogen: `modules/impermanence-server.nix` marks `/persist` `neededForBoot`, so sops
  secrets install at boot. `sops-install-secrets` runs from the initrd activation script,
  which executes before the ordinary fileSystems are mounted -- activation ran at 14:42:35
  and `/persist` was mounted at 14:42:38, so the age key at `/persist/secrets/age-keys.txt`
  was unreadable, `setupSecrets` failed, `/run/secrets` was never created, and every
  sops-consuming unit died with `243/CREDENTIALS`: paperless-{web,consumer,scheduler},
  `nextcloud-setup`, `acme-order-renew-luckyobserver.com`, and both borg jobs. The failure
  was self-concealing -- any later `nixos-rebuild switch` re-runs activation with `/persist`
  mounted and silently repairs `/run/secrets` -- so it was only visible between a reboot and
  the next rebuild, and had been failing on every boot since at least Jul 15. Verify this one
  across an actual reboot, not a rebuild.

- sulphur: dropped flameshot entirely; `<Ctrl><Alt><Shift>s` now uses gnome-shell's
  built-in `area-screenshot-clip` (area select to clipboard, no portal round-trip).
  Flameshot on GNOME Wayland needed three stacked workarounds -- `systemd-run` for
  portal app-id attribution, `QT_QPA_PLATFORM=xcb` for a multi-monitor overlay, and
  `QT_FONT_DPI=96` for the overlay origin under 1.25 scaling -- and still discarded
  the selection, saving the full 4000x3040 desktop instead of the crop. Not worth
  carrying; the shell's built-in has none of these failure modes.
- sulphur: `home-manager.backupFileExtension = "hm-bak"` — a single unmanaged file HM
  wanted to own previously failed the whole activation and with it `nixos-rebuild switch`.

### Added (impermanence install)
- `install.sh`: new mode 3 "Impermanence (Btrfs, no encryption)" for unattended remote
  reboot (no LUKS prompt); a `/data` disk prompt that mounts an existing partition by
  detecting its UUID + fstype via `blkid` (no reformat); and an optional sops age-key
  install step. All disk-dependent values are written into the generated
  `hardware/<host>.nix`.
- `modules/impermanence-server.nix`: layout-only Btrfs/`/persist` module for hydrogen
  (no LUKS, no active root-wipe; matches sulphur's real behaviour).

### Changed (impermanence install)
- `hosts/hydrogen.nix`: now imports the installer-generated `hardware/hydrogen.nix`
  (single source of disk UUIDs) + `impermanence-server.nix`; inline `fileSystems`/`boot`/
  `swapDevices`/`hostPlatform`/microcode removed; `networking.useDHCP = false` (plain).
