# Changelog

Also the decision log. Rationale that would otherwise bloat a code comment lives here.

## Open

- **Narrow `pcie_aspm=off` on sulfur** to `pcie_aspm.policy=performance`, or disable the SD
  reader via udev. Disabling ASPM fleet-wide costs idle battery.
- **Off-box failure notification.** `nixos-upgrade` failures notify the logged-in desktop,
  which on the four kids' laptops is a child who cannot act on it. Needs ntfy on hydrogen.
- **Stop sharing `sheath-password-hash` with the kids' laptops.** A child with wheel can read
  the family age key and offline-crack a hash that is also sheath's password on hydrogen and
  sulfur. Give the laptops their own admin hash.
- **`modules/bridge-slave-restore.nix` retirement gate.** Delete once two consecutive
  nightlies pass with no repair logged. A repair logged after 2026-08-13 is itself the
  finding: scripted networking is detaching its own slave, and `br0-netdev`'s
  `X-ReloadIfChanged` is the next suspect.

## 2026-08-26 (read-only Porkbun domain search)

- **Codex, Claude Code, OpenCode, and Qwen Code can query Porkbun.** The pinned MCP build
  exposes only credential validation, availability, and pricing; registration, account, and
  DNS tools do not exist in its tool surface. SOPS supplies a dedicated key at process start.
- **RE containers omit Porkbun; `ccodex` includes it.** The RE agents do not need registrar
  access, while the general Codex container receives only the two required secret files.

## 2026-08-21 (isolated Codex)

- **`ccodex` runs Codex `--yolo` inside rootless Podman.** The current working tree, a dedicated
  `ccodex-home` volume, and the host `~/.codex` directory are writable; SSH/GPG agents, the rest
  of the host home, and other projects are not mounted. Sharing `~/.codex` makes login, settings,
  plugins, and conversations immediately available to both `codex` and `ccodex`, at the explicit
  cost of exposing those credentials and files to the yolo agent. `ccodex login` runs on the host
  so its browser can reach the localhost callback. The bind mounts preserve the absolute host
  paths of both `~/.codex` and the current project because Codex's thread database and project
  trust records are path-sensitive. Podman assigns each invocation a unique container name, so a
  stale or concurrent session for the same project cannot block startup. The launcher supervises
  the container ID and uses Ctrl+C as the Podman detach key, then stops and removes the container
  on exit, detach, hangup, or termination. Thus Ctrl+C exits `ccodex` instead of merely interrupting
  the current Codex turn. The host Nix store is read-only and the daemon socket remains available,
  so `nix develop`, builds and flake checks work as they do in `cclaude`.

## 2026-08-21 (SSH and Wi-Fi path repair)

- **Disabled libvirt's unused SSH proxy include.** OpenSSH 10.5 rejected libvirt's
  Nix-store-owned proxy snippet as having a bad owner, so every ordinary SSH command on
  sulfur aborted while reading `/etc/ssh/ssh_config`, before attempting a connection.
  `virtualisation.libvirtd.sshProxy = false` removes that global include without disabling
  libvirt or virt-manager; direct SSH and the fleet host aliases continue unchanged.
- **Sulfur's `hydrogen` alias now uses the LAN recovery path.** Hydrogen was healthy and
  accepted the personal key at `10.0.0.10`, while `wgadm` had stopped handshaking after
  sulfur boot and timed out at `10.42.0.2`. Routine administration should not depend on
  the component the recovery listener exists to bypass; `hydrogen-wg` retains the tunnel
  address for explicit testing and off-LAN diagnosis.
- **The outage was the GT-AXE16000's 2.4 GHz QoS path, not routing.** Merlin 3006.102.7's
  Broadcom voice queue expired 5,689 frames while transmitting 207; packet captures showed
  EF-marked SSH and AF41-marked WireGuard replies vanish at that radio. Upgrading the AP to
  3006.102.8_2 eliminated marked-packet loss in both directions; sulfur still prefers 5 GHz
  for link quality rather than correctness.
- **`wgadm` endpoints refresh on uplink activation.** Native WireGuard resolves its endpoint
  FQDNs only when the generated peer units run, so a laptop could carry a home split-DNS
  address away or a public address home. NetworkManager now restarts the interface on a real
  uplink `up`/DHCP change; no polling, probing, or scheduled correction.

## 2026-08-19 (codex CLI)

- **`codex` 0.147.0 on sulfur.** Package only -- no declared config: it authenticates by
  `codex login` against a ChatGPT account and owns `~/.codex` itself. Not wired to the vLLM
  endpoint; opencode/qwen-code already cover that path.

## 2026-08-19 (nextcloud 34, and the admin path that was a single point of failure)

- **PostgreSQL collation drift repaired first.** Every database on hydrogen was created at
  collation version 2.40 while the server had moved to 2.42, so text indexes were built to
  rules glibc no longer follows -- wrong ordering, and unique constraints that stop catching
  duplicates. `REINDEX DATABASE` + `REINDEX SYSTEM` + `ALTER DATABASE ... REFRESH COLLATION
  VERSION` on nextcloud, immich, postgres and template1. 20s of downtime; immich was the only
  slow one at 18s. Running a schema migration over stale indexes is how a latent fault becomes
  a corrupt one, so this went first.
- **Nextcloud 32 -> 33 -> 34**, sequentially, because Nextcloud refuses multi-major jumps.
  Declaring the package *is* the upgrade: `nextcloud-setup.service` migrates the schema during
  activation. Not reversible by generation rollback -- the older code refuses a newer schema,
  so a real rollback restores `/var/lib/nextcloud` and the database together.
- **wgadm gained a retry.** `networking.wireguard.interfaces` generates Type=oneshot +
  RemainAfterExit units, so a failed start left no interface and nothing to retry it. A switch
  restarted wgadm, it did not come back, and hydrogen had no remote management path at all --
  recovery was the physical console. `OnFailure` now triggers a retry bound to the failure
  event rather than a clock, rate-limited so a wedged interface cannot become a restart loop
  that hides its own cause.
- **sshd now listens on br0, key-only.** br0 deliberately carried nothing, which is what turned
  one unit failure into a trip upstairs. The router does not forward 22, so this widens reach to
  the house, not the internet; every other service stays wgadm-scoped. `PasswordAuthentication`
  is off here because the LAN is not a trusted network and sheath's hash is shared with the
  kids' laptops.
- A single management path whose availability depends on a service that rebuilds restart is not
  a boundary, it is a trip-wire. The boundary is key possession; that has not changed.

## 2026-08-19 (flake.lock describes the fleet again)

- **The nightly no longer overrides nixpkgs.** `system.autoUpgrade` ran with
  `--override-input nixpkgs <branch> --no-write-lock-file`, so it advanced the running system
  and never recorded where to. `nr`, `nb` and any hand-run `nixos-rebuild` build the lock, so
  every manual rebuild was a rollback of however far the nightly had drifted -- by
  construction, not by accident. sulfur booted 20260817 while the lock said 20260813.
- **What that cost.** nixpkgs added `X-RestartIfChanged=false` to
  `gnome-session-monitor.service` between 20260816 and 20260817. Rolling back stripped the
  guard, so `switch-to-configuration` stopped the unit; the whole session hangs off it
  (`gnome-session-pre.target` -> `gnome-session@gnome.target`), so the desktop died mid-switch.
  The dying session took the terminal holding `systemd-run --pipe`'s stdio with it, the next
  `eprintln!` panicked on EPIPE (exit 101), and activation aborted before the start phase --
  leaving mullvad, asusd and `local-fs.target` stopped. Every hand-run switch did this.
- **hydrogen owns the lock.** `fleet.lockUpdate` bumps nixpkgs nightly at 01:00, runs
  `nix flake check` -- every host's toplevel plus the installer -- and pushes only if all of
  them build. A revision that breaks any machine in the fleet now reaches none of them, where
  before each host resolved the branch tip independently with nothing gating it. One writer:
  a second is a push race.
- Not a scheduled mutation in the sense this repo forbids: it is an update cadence, the same
  class as the nightly rebuild it feeds, and reconciles nothing against a clock.
- `staleCheck` keeps its job and gains a second one -- a wedged lock updater stalls the fleet
  silently, and the 21-day age check on each host is what notices.
- `nu` gained the same gate. It committed and pushed the lock before anything built it, which
  is the identical bug at manual speed.

## 2026-08-19 (mullvad cannot brick sulfur)

- **Lockdown mode pinned off, and every Mullvad setting re-asserted rather than set once.**
  `modules/mullvad.nix`. Roughly quarterly an upgrade migrates `/etc/mullvad-vpn/settings.json`,
  `block_when_disconnected` comes back on, and the daemon blocks every packet; the symptom is
  "DNS times out", which is why it cost hours each time. Availability beats the kill switch on
  a laptop that is not always meant to be tunnelled.
- **Two events, no schedule.** `mullvad-configure` is pulled in by `mullvad-daemon.service`,
  so every daemon start -- which is what an upgrade does, and what migrates the settings --
  lands on the declared state; `restartTriggers` on the generation label re-runs it on every
  `nixos-rebuild switch`, so an update always resets Mullvad. It was `wantedBy` boot alone, and
  so never re-ran on the one event that causes the drift.
- `RemainAfterExit`, because switch-to-configuration does not reliably re-run a *changed*
  oneshot that is inactive; staying active makes the per-generation restart deterministic.
- A scheduled re-assert was built first and removed, along with a polling notifier: a timer
  makes the system's behaviour depend on when you looked at it. Convergence belongs on the
  event, not on a clock.
- The unit reads each setting before writing it and writes only what differs, so a line in its
  journal means something genuinely drifted. An unparseable value counts as drift -- a reworded
  CLI must fail towards enforcing, not away from it.
- Clearing the setting is not enough: the daemon keeps its `Blocked` firewall policy until the
  tunnel state is touched, so the assert also issues `disconnect` when it finds drift.
- **`mullvad-unblock`** is the manual escape hatch. Last resort it deletes the `inet mullvad`
  nftables table: those rules outlive the daemon, so a daemon that dies while blocking leaves
  nothing else that can undo them.

## 2026-08-18 (private git on hydrogen)

- **Bare git repos on hydrogen, served by sshd.** `modules/git-server.nix` adds a `git`
  system user whose shell *is* `git-shell`, owning `/var/lib/git`. Chosen over a forge
  (Forgejo/gitea): a forge brings a database, a web surface on the wildcard vhost, and an
  account model to keep in step, none of which a single-user private remote needs. Repos
  stay plain directories, so a Borg restore hands them back working with no import step.
- **No new port and no change to the access boundary.** sshd already answers on wgadm and
  wgfam, so the git account is reachable from the kids' laptops too and only key-only auth
  keeps them out -- the same trade already made for the Minecraft control channel.
- **`git-repo create|list|delete`** on hydrogen, root only. `delete` demands the repo name
  typed back: the only other copy is whatever the last Borg run took.
- **sulfur reaches it as `hydrogen-git:<name>.git`**, an SSH alias of its own rather than
  `Host hydrogen`, so `User git` cannot capture an admin ssh to the same address. First
  clone is trust-on-first-use; no host key is pinned for hydrogen anywhere in the fleet.

## 2026-08-14 (minecraft pre-launcher)

- **A pre-launcher for everything that is not the couch.** sulfur and the kids' laptops baked
  one player name and one server address in at build time and quick-played straight into
  them; `docs/minecraft.md` carried "No GUI launcher" as a known limitation. Now: pick a
  player, pick a world, and the world is started before the game is. The plain **Minecraft**
  icon still quick-plays into the family server and is the faster route there.
- **Worlds are rootless podman containers, created on first play.** Built from
  `packages/fabric-server.nix`, not a `docker.io` pull, so a container world and hydrogen's
  shared world are the same build with the same mods and datapacks. No `--userns=keep-id`:
  container root maps to the invoking user, so a plain bind mount needs no `,U` chown.
- **The version pin was in the wrong place.** It lived in `modules/minecraft-server.nix` as a
  NixOS-module overlay, so it applied to hosts but not to the flake package set — the first
  image built against the channel's 26.2, compiled for Java 25, and died on fabric-server's
  JDK 21 with `UnsupportedClassVersionError`, past every assertion.
  `packages/minecraft-version.nix` says the version must "not be a property of whichever
  nixpkgs a host builds from"; the override now sits in `packages/default.nix`, where that
  is true.
- **Readiness is RCON, not a TCP connect.** Rootless podman's port forwarder accepts
  connections on the published port immediately — measured answering in 5 s against a server
  still unpacking its jar. Only the server itself can say it is up.
- **The menu widgets moved out of `minecraft-couch.nix`** into `packages/minecraft-menu`,
  which took that module from 975 lines to 770. Two launchers wanting the same on-screen
  keyboard is where one copy stops being cheaper than two.
- **hydrogen's control channel is SSH behind a forced command.** A dedicated `mcctl` user
  with lingering, whose keys can run only `minecraft-server-ctl` subcommands — a key off a
  child's laptop is not a shell on the 24/7 box. Consequence, per the guest note in
  `modules/family/peers.nix`: opening 22 on `wgfam` also exposes sshd to guest keys, and
  key-only auth is what stops them.
- Ports are a **range** (25566-25575) rather than per-server entries, because firewall ports
  are declarative and per-interface: a container created at runtime on a fresh port would be
  unreachable until the next rebuild. The new worlds join `backupPaths` and are bracketed by
  RCON `save-off`/`save-on`, the container equivalent of the console-FIFO flush.

<!-- TODO: per-laptop `mcctl-key-<kid>` entries in secrets/family.yaml, mirroring
     `wg-priv-<kid>`, so each child's launcher can drive hydrogen. Until then
     fleet.minecraftServers.authorizedKeys is empty and only sheath can, over wgadm.
     Deliberately per-host rather than one shared key -- the standing "stop sharing
     sheath-password-hash with the kids' laptops" item is the same mistake. -->

## 2026-08-14 (installer dashboard)

- **The installer is one screen, and every row is checked before anything runs.** The
  five-screen wizard hid its own holes: the options screen had no forward key at all, and
  nothing told you a choice was wrong until the phase depending on it failed minutes later.
  Each row now has a validator that answers "does this work", not "is it set" -- the layout
  row builds `diskoScript`, so disko itself accepts the layout before a disk is touched, and
  the age row really decrypts the key. `r` is refused until every row is satisfied.
- **Encryption defaults to off.** `fleet.disk.system.encrypt` defaulted to `true`, so *not*
  selecting LUKS still produced a passphrase prompt during the first real install -- an
  opt-out default dressed up as an opt-in list. An un-chosen default that costs a wipe to
  discover is a bad default whichever way it points. Committed layouts state the value
  explicitly, so no host changed behaviour.
- **`age -d` cannot be fed a passphrase on stdin** -- *"standard input is not a terminal,
  and /dev/tty is not available"*. `script(1)` supplies a pty, the passphrase arrives on its
  stdin so it never reaches argv, and `script -e` propagates age's exit status; a wrong
  passphrase writes no output file. That removed the last interactive step, so the run is
  now unattended from `ERASE` to a booted system, and the same call validates the passphrase
  while the board is still being filled in. `script` is util-linux, so it is on every ISO.
- **A dry run cannot write the layout.** The layout check writes `disk-config/<host>.nix` to
  validate it; run against an already-installed machine that file would set
  `fleet.disk.enable = true` and the next local rebuild would try to replace its live
  filesystems. `--dry-run` now reports the profile as valid without writing or building.
- The ERASE confirmation stays. Validation proves the configuration is right, not that it is
  aimed at the correct machine.
- **The installer carries its own tools.** The minimal ISO has no `age` and no `mkpasswd`,
  so the environment check failed on the real thing. The package now wraps the binary with
  `--suffix PATH` over age, mkpasswd, util-linux, openssh, git and coreutils: the ISO's
  copies still win where they exist, and these fill the gaps. `nix`, `nixos-install`,
  `nixos-generate-config` and `nixos-enter` are deliberately left out -- those must come
  from the running installer environment, not from this checkout's nixpkgs.

## 2026-08-14 (later)

- **Disk layout is declarative: `modules/disk-layout.nix` renders `fleet.disk.*` into
  `disko.devices`.** The old installer partitioned imperatively and then described the same
  disk a second time in a shell heredoc. Two descriptions, maintained by hand, had already
  drifted: generated `/boot` used `fmask=0022` where every committed host uses `0077`, and
  generated `/` was `subvol=@root` where `hardware/sulfur.nix` is a tmpfs. One description
  now drives both, so they cannot disagree.
- **The `by-id` path is format-time only.** disko mounts by
  `/dev/disk/by-partlabel/disk-<disk>-<part>`, so a committed layout is machine-independent
  and `disko --mode mount` needs no disk id. That is what makes resuming after a live-ISO
  reboot possible at all, and it is why `hardware/_placeholder.nix`'s label-matching hack is
  no longer load-bearing.
- **disko does not set `neededForBoot`.** It emits only `device`, `fsType` and `options`. The
  module adds it for `/nix`, `/home`, `/persist` and `/var/log`; without it sops-install-secrets
  fails during initrd activation. Highest-risk omission in the migration, and silent.
- **The age key went to the wrong place for sulfur.** The old installer chose the destination
  from the *disk layout* -- impermanence meant `/persist/secrets/age-keys.txt`. Only
  `modules/impermanence-server.nix` (hydrogen) actually moves `sops.age.keyFile` there;
  sulfur imports `modules/impermanence.nix`, which does not, so its key landed where nothing
  reads it. Evaluated, not assumed: sulfur wants `/home/sheath/.config/sops/age/keys.txt`.
  The installer now asks the host's own configuration, which also picks the family key from
  `sops.defaultSopsFile` rather than a hardcoded host list, and drops the
  `/persist/secrets/sheath-password` file nothing ever read.
- **Family laptops may now use LUKS, btrfs and `/persist`.** The "family must be mode 1"
  restriction existed only because the age-key path was inferred from the layout. With it
  derived, encryption and impermanence became independent choices.
- **A TUI installer in Rust replaces the shell one** (`installer/`, `nix run .#installer`).
  Every option is chosen and reviewed before anything executes; the layout is saved to
  `disk-config/<host>.nix`, which is the single source of truth and the file that has to be
  committed anyway. Phase completion is derived by inspecting the target rather than trusting
  a scratch file, so a fresh run, a resume and a deliberate re-install take the same path.
  State lives on `@persist` because `/tmp` dies with the ISO and a tmpfs root evaporates on
  reboot. The repo's first Rust package; `nix run` resolves it via `meta.mainProgram`, and
  `checks` names it explicitly because that attrset is otherwise hosts-only.
- **The run screen offers `m` before `r`.** After an ISO reboot nothing is mounted, so every
  phase reads as pending -- and the destructive one is first in the list. Without an explicit
  "mount the existing target" step, a resume would have re-partitioned an installed machine.
- **hydrogen stays unencrypted.** `modules/auto-update.nix` reboots the fleet unattended; an
  encrypted headless server would come back up waiting at a passphrase prompt nobody is
  watching. Encryption is per-host, not fleet-wide.
- `install.sh` is kept until the TUI has completed a real install. Deleting the only working
  installer before its replacement is proven would leave no way to install a machine.

<!-- TODO: verify a two-disk encrypted layout boots from ONE passphrase. Both volumes
     format from one shared key file, so the headers hold identical passphrases -- confirmed
     by reading the generated diskoScript. Whether systemd's password cache then opens the
     second without a second prompt needs a real boot. Worst case is two prompts, never a
     failed boot. Automating this against disko's own VM harness was abandoned: it hardcodes
     checkScripts = true, which its two-askPassword script then fails on. -->

## 2026-08-14

- **`install.sh` could not install a family laptop, and found out after `mkfs`.** The host
  picker listed `ls ./hosts`, and `a3d1f31` had deleted the four `hosts/<kid>.nix` files that
  morning when it moved family hosts to `genAttrs` -- it reasoned about preserving the
  per-host *hardware* overwrite contract and did not notice the *selection* one. Because the
  picker ran after `sgdisk`/`mkfs`, a family install wiped the disk and then aborted, silently
  under fzf (`set -e` on fzf's exit 1). Host selection and the family-only validation now run
  before anything destructive, the list is `hosts/` plus `family_hosts()`, and `family_hosts()`
  joins in Nix rather than python3 -- the installer ISO has neither python3 nor flakes on, and
  both misses hit the same hard exit.
- **Filesystem labels now match `hardware/_placeholder.nix`** (`BOOT`/`nixos`, was `EFI`/`root`),
  and the placeholder emits a `warnings` entry naming the host. Every machine rebuilds from the
  repo (`modules/auto-update.nix`, and the `nr`/`nb` aliases), so a host whose real hardware
  config was never committed switches to the placeholder's dummy filesystems and dies at the
  next boot -- `nixos-rebuild` does not validate mounts, so the nightly reports success. The
  labels make that survivable; the warning makes it visible. hydrogen and sulfur were never
  exposed. The real fix is still to commit each machine's generated config: the other three
  laptops are outstanding.
- **`modules/oryp10.nix`**: System76 Oryx Pro 10 support for gentlemenpupil, recovered from
  `hosts/osmium.nix` at `e560e78^` -- the same physical machine before it was handed down, so
  the PRIME bus IDs and the fall-off-the-bus workarounds (`pcie_aspm=off`, `nvidiaPersistenced`,
  `finegrained = false`) are measured, not inferred from the model. Dropped from osmium:
  `mitigations=off` (this is a child's web-browsing laptop now), `scsi_mod.use_blk_mq=1` (no-op
  since 5.0), and the docked lid-switch overrides. `open = false` is osmium's proven value and
  is the one thing here not re-verified against the current 595 driver.
- **`flake.nix`: family hosts take `extraModules`**, the seam `mkHost` already had and the
  `genAttrs` branch lacked. `familyHosts` is now hostname → modules.
- `install.sh` chowns `/home/sheath` after install. The checkout and age key are written as
  root and `users/sheath.nix` sets no `createHome`, so NixOS never fixed it: sheath could not
  read her own age key or use git in `~/nixos`. Boot worked, since sops-nix reads it as root,
  which is why it went unnoticed.
- **Ptyxis → Ghostty on sulfur (`home/ghostty.nix`).** Ptyxis' home-manager module only
  installed the package, so font and login-shell had to be GSettings in `modules/dconf.nix`,
  split away from the module that owned the terminal; `programs.ghostty` writes a real config
  file, so both `org/gnome/Ptyxis*` blocks are gone. Two non-obvious carry-overs: `font-size`
  is 14, not 11, because GNOME's 1.25 `text-scaling-factor` is applied by VTE but not by
  Ghostty; and `command = "direct:bash --login"` replaces `login-shell = true`, which is
  load-bearing for `home.sessionPath` (it reaches `~/.profile`, not `.bashrc`).
- **`pkgs.ghostty.terminfo` on every host, and in the RE container image.** Ghostty sends
  `TERM=xterm-ghostty`; nixpkgs' ncurses ships only a bare `ghostty` entry, so an SSH session
  to any other host — and any TUI in the container, which inherits the host's `TERM` — would
  hit the same no-terminfo repaint flicker `packages/re-container.nix` already guards against.
  8 KB per host, versus pinning `term = xterm-256color` and losing the capability advertising.
- Bumped `openwebui-model` in `secrets/secrets.yaml` to the endpoint's newer served model.
  `contextWindow`/`maxOutput` in `modules/vllm-endpoint.nix` were left alone -- the endpoint
  was serving no models when the change was made, so its `/models` could not be re-read.
- Removed `gen-family-secrets.sh` and `gen-mobile-peer.sh`. Both were one-shot bootstrap
  tools that had already done their job: the family secrets exist and are edited in place
  with `sops`, and a phone's keypair is generated on the device. The enrolment settings the
  QR script encoded now live in `modules/family/peers.nix`, next to the values they use.
  Recover either from git history if a full re-bootstrap is ever needed.
- `CLAUDE.md` is now one file, deployed to `~/.claude/CLAUDE.md` by `modules/workstation.nix`
  via `.source`. It previously existed twice: a repo copy and a ~100-line heredoc in
  `workstation.nix`, which had to be kept in step by hand.
- Comment policy: terse, why-only, three lines maximum. The old "generous comments" rule had
  produced 3,508 comment lines across 9,889 lines of Nix.
- Removed the session-log mandate; `docs/CHANGELOG.md` is the only log and doubles as the
  decision log. `docs/SESSION_LOG.md` deleted.

## 2026-08-13

- **`hosts/hydrogen.nix`: NetworkManager off (`mkForce false`).** Two things each believed
  they owned the network — scripted `networking.bridges` (which owns `br0` through
  `br0-netdev.service` and reloads it on most switches) and NM, present only because GNOME
  sets it `mkDefault true`. NM earned nothing here: no profiles, no wifi, not the DNS source.
  Not a proven fix for the outage below — it removes the bug class, not a demonstrated actor.
- **`modules/bridge-slave-restore.nix`: 30 s watchdog re-attaching detached bridge slaves.**
  The nightly rebuild *succeeded* and left hydrogen unreachable for six hours; `br0` lost
  `enp0s31f6` 30 ms after "Reloaded Bridge Interface br0" and nothing put it back. Two live
  reproductions cleared NM as the actor, so this is a bound rather than a diagnosis. Every
  repair logs at warning level — those lines appearing *is* the reproduction.
  `AccuracySec = "5s"` is load-bearing; systemd's 1-minute default would make a 30 s period
  meaningless.
- **`hosts/hydrogen.nix`: `nvidiaPackages.production` → `legacy_580`.** The nightly moved the
  Quadro P4200 (Pascal) onto 595.71.05, which does not support it, and the host did not come
  back. **A pin to a moving branch name pins nothing** — `production`, `stable` and `latest`
  all crossed the 590 boundary the same day. `legacy_580` names the support branch itself:
  R580 is the last one supporting Maxwell/Pascal/Volta, with Quadro security updates through
  October 2028. Holds until the card is replaced.
- **`hosts/sulfur.nix`: `SendSIGKILL` forced on `asus-shutdown.service`.** asusctl 6.3.x traps
  SIGTERM and defers exit; with upstream's `SendSIGKILL=no` and `TimeoutStopSec=45` systemd
  cannot reap it, so the switch burned 90 s and exited 4. `restartIfChanged = false` does not
  help — the unit is `PartOf=asusd.service`, so an asusd restart propagates a stop anyway.
  The fix has to sit at the kill layer. Recurs on any rebuild that moves asusctl's store path.
- **`hosts/sulfur.nix`: `ExecCondition` on `dock-monitors-hotplug.service`.** The udev rule
  fires on DRM events with no graphical session behind them, so the script hit a dead session
  bus and left a failed unit — which `switch-to-configuration` counts, turning a clean nightly
  into a failure report. A failing `ExecCondition` marks the unit skipped, not failed, so a
  genuine DBus error in a live session still surfaces.

## 2026-08-11

- **`hardware/sulfur.nix`: `pcie_aspm=off`.** 26.11 (Linux 6.18.44) would not boot — the
  Realtek RTS525A card reader stormed correctable AER errors (Replay Timer Timeout) every
  ~150 µs and the kernel spent the whole boot in the AER handler. The fault predates the
  channel move: 26.05 logs ten per boot before the reader suspends. 6.18.44 never lets it
  settle. Zero AER errors after the fix.
- **`hosts/sulfur.nix`: `NVreg_DynamicPowerManagement=0x00` set explicitly.**
  `powerManagement.finegrained = false` does not disable RTD3 — it omits the modparam and
  lets the driver default apply. 595.71.05 defaulted to 0; 610.57.04 defaults to 3 and turns
  RTD3 on, which deadlocks Mutter against a D3cold GPU driving the dock's HDMI output. An
  absent modparam means "driver default", not "off".
- `hosts/sulfur.nix`: kernel unpinned. The `linuxPackages_6_18` pin was already inert and
  would only have frozen the laptop on 6.18 after nvidia-open could handle newer.
- `modules/auto-update.nix`: failed nightly rebuilds now raise a critical desktop
  notification. Two units — `OnFailure` catches someone at the machine at 04:45, and a
  user unit re-checks `systemctl is-failed` at login, which is what actually happens on a
  laptop that was off overnight. Enumerates `/run/user/*/bus` rather than hardcoding a
  username. Every path ends in `|| true`; a broken notifier must not turn one failed unit
  into two.
- Fleet split onto two channels (five laptops unstable, hydrogen 26.05). **Superseded
  2026-08-14 — see the single-channel change.**
- `packages/minecraft-version.nix`: the 1.21.10 hold and jar url/sha1, lifted out of the
  overlay so the version cannot be a property of whichever channel a host builds from.
- `home/vscode.nix`: `programs.vscode` → `programs.vscodium`. Under the old wiring every
  setting and extension was silently inert.

## 2026-08-10

- **Fleet moved from nixpkgs 25.11 to 26.05.** Signal Desktop hard-expires ~90 days after
  release and refused to start. The channel was the problem, not the package: `nixos-25.11`
  stopped receiving commits on 2026-06-30, so no backport of anything was ever going to
  arrive. `modules/auto-update.nix` had pointed at the EOL branch for six weeks and the job
  never failed — a frozen branch still resolves, still builds, still exits 0.
- `packages/minecraft-client-launcher.nix` rewritten for portablemc 5.0.3 (a Rust rewrite of
  the 4.4.1 Python tool). Four CLI flags moved; `--work-dir` no longer exists. A runtime break
  no build catches. **`--bin-dir` is the trap:** it derives from `--main-dir`, not `--mc-dir`,
  so natives extract into the read-only payload without it. `--fetch-exclude-all` replaced
  `--timeout`, which strengthened the offline guarantee — the manifest fetch is never made.
- `modules/minecraft-server.nix`: overlay holding `minecraft-server` at 1.21.10; 26.05 ships
  1.21.11 and the version-lockstep assertions correctly refused it.
- 26.05 renames: `nodePackages.bash-language-server` → top-level, `extraLuaConfig` → `initLua`,
  `services.asusd.enableUserService` removed, `immich.database.enableVectors` removed,
  `networking.wireless.enable` needs `mkForce` under NM.

## 2026-08-09

- **sulfur's tunnels became NetworkManager profiles.** NM manages WireGuard devices whether
  or not we want it to, so the real choice is NM-as-spectator or NM-as-owner — and the
  spectator is the dangerous one, offering a GNOME toggle that flushes address and routes out
  from under a systemd unit that goes on reporting success. Keys stay in sops and reach NM
  over D-Bus via `nm-file-secret-agent`; they never land in a connection file. Do not edit
  these in the GNOME UI — NM copies an edited connection to `/etc` and you get two competing
  profiles.
- `modules/wg-unmanaged.nix`: every WireGuard interface marked unmanaged, on every host.
- `hosts/sulfur.nix`: Mullvad DNS set to `1.1.1.1` alone. It had listed the home router first,
  which is reachable only through a tunnel; glibc has no notion of an unreachable nameserver,
  only a slow one, so every lookup ate a 5 s timeout. A resolver whose reachability depends on
  a tunnel must never be first in `resolv.conf`.

## 2026-08-06

- **Every service on hydrogen moved behind WireGuard.** `modules/minecraft-server.nix` runs
  `online-mode=false` and verifies no identity, so whatever reaches 25565 may claim to be any
  child — scoping it to `br0` meant "any device on the LAN, including a guest phone". Two
  hubs: `wgadm` (sulfur, full admin) and `wgfam` (family devices, web + game only).
- **`services.openssh.openFirewall = false`.** It defaults true and adds 22 to the *global*
  `allowedTCPPorts`, so removing the `br0` entry did nothing for three days. An
  interface-scoped rule cannot subtract from a global one.
- The FORWARD policy is built as one `family-forward` chain rather than four rules; the
  per-rule delete-then-append version left a partially-applied ruleset on first switch.
- Four kids' laptops added. `modules/family/profile.nix` derives username, peer address, sops
  key names and Minecraft handle from the hostname via `modules/family/peers.nix`.
- Renumbered every tunnel to `.1` router, `.2` hydrogen, `.3` sulfur. The router is the only
  resolver. Never route the LAN gateway into a tunnel — listing `10.0.0.1/32` in `allowed-ips`
  put a more-specific route to the machine's own gateway and DNS server inside the tunnel and
  killed all internet access.
- QR provisioning for phones and tablets (`gen-mobile-peer.sh`).

## 2026-08-05

- `modules/backup.nix`: third Borg repo on hydrogen's root SSD. `/data` is btrfs RAID0 across
  two USB disks with no redundancy and held both the Immich media and the local repo, so a
  `/data` failure left one copy, offsite, and a 180 GB WAN restore. An independent repo, not
  an rsync mirror — a mirror copies damage and collides on Repository ID.
- Prism Launcher replaced by an offline, Nix-pinned client (`packages/minecraft-client`). The
  flake plus the archive dir rebuild a playable client with no network at all.

## 2026-08-04

- Minecraft server runs Fabric (`packages/fabric-server.nix`) for recipe viewing and chest
  crafting.
- **`hosts/hydrogen.nix`: `SleepOperation = ""` on logind.** The masked sleep targets turned a
  refusal into a livelock — logind retried ~240×/s, burned 75% of a core and wrote 7M journal
  lines in four hours, evicting the day's logs including the backup window. Nothing asked it
  to suspend; it re-queried the masked target on its own. The masks stay as the last line of
  defence, but logind must never *initiate*.

## 2026-08-03

- Veloren server disabled. rtsim never idles: 20.7% of a core with zero players connected,
  versus 0.10% for the Minecraft server, which does pause when empty.
- Couch Minecraft pre-launcher replaces MAC-pinned controllers. Identity became a property of
  the person rather than the hardware — picking up a sibling's pad no longer logs you in as
  your sibling, and pads are interchangeable.

## 2026-07-30

- Agentic RE stack: `modules/opencode.nix`, `modules/qwen-code.nix`, both pointed at ReVa's
  MCP server and a remote vLLM endpoint, sandboxed by `modules/re-container.nix` as `cqwen`
  and `copencode`. `prompts/re-agent.md` is the single canonical prompt for both.
- **vLLM stays remote and is not a NixOS service anywhere in this flake.** The only always-on
  GPU box is hydrogen, whose Quadro P4200 is Pascal (SM 6.1), and vLLM hard-requires compute
  capability ≥ 7.0. Still true on unstable.
- Containment bounds the filesystem, not the Ghidra database: all 88 ReVa tools are
  auto-approved in both clients, including the 14 write tools. MCP calls do not go through the
  shell allow-rules.

## 2026-07-29

- `packages/ghidra-reva.nix`: Ghidra 12.1 + ReVa 7.3.0. The extension is a hard version match,
  not a floor. Still needed now that unstable ships ghidra-bin 12.1.2, because ReVa 7.3.0
  publishes no asset for 12.1.2.
- kitty → ptyxis; host renamed `sulphur` → `sulfur`.

## 2026-07-21

- **RustDesk is the remote desktop on hydrogen.** It captures through the xdg-desktop-portal
  ScreenCast path, which works on this NVIDIA+Wayland box. `gnome-remote-desktop` RDP (blank
  frames, upstream mutter bug) and Sunshine KMS capture (`GL_INVALID_VALUE`) were both tried
  and abandoned — do not re-attempt them.
- `modules/impermanence-server.nix`: `/persist` marked `neededForBoot` so the age key is
  readable before `sops-install-secrets-for-users` runs. Without it the failure conceals
  itself.
- Flameshot dropped for gnome-shell's built-in area screenshot — unusable on GNOME Wayland
  (portal app-id, single-monitor overlay, HiDPI origin, discarded crop).
- `home-manager.backupFileExtension` set, so a pre-existing file cannot fail the whole
  activation and with it the rebuild.

## 2026-07-15

- hydrogen: postgres 15 → 17 (dump/restore), `stateVersion` 23.11 → 25.11. The package is
  pinned explicitly so a future `stateVersion` bump cannot silently trigger another major.
- Nightly `system.autoUpgrade` enabled for security updates.
- NOPASSWD sudo for sheath on hydrogen, for unattended remote administration.
- `nr`/`nb` deploy against the pinned lock; `nu` is the deliberate input bump.

## 2026-06

- hydrogen: Nextcloud, Immich, calibre-web and paperless behind nginx with a single wildcard
  `*.luckyobserver.com` cert, issued by the Cloudflare DNS-01 challenge — which validates with
  a TXT record, so it works for hosts with no public A record and no inbound 80/443.
- Borg backups with pg_dumps taken just before each run; button-driven fi-7160 scanning into
  paperless via scanbd (no upstream NixOS module).
- `modules/ollama.nix`: `cudaCapabilities = [ "6.1" ]`. Pascal is outside nixpkgs' default
  gencode set, so stock `ollama-cuda` detects the card and falls back to CPU with
  `total_vram="0 B"`.
- hydrogen static IP moved to 10.0.0.10; impermanence-style install.

## Earlier (2025-09 – 2026-05)

Fleet bootstrap: flake layout, impermanence on sulfur (tmpfs root, LUKS-on-NVMe, btrfs
subvolumes), sops-nix, home-manager, GNOME, Steam/gaming, WiVRn, virtualisation, the Cynthion
and scanner tooling, and `install.sh`. Notable fixes that still matter:

- `i915.enable_dpcd_backlight=3` on sulfur — the panel needs the HDR/VESA DPCD interface;
  nixos-hardware's asus module sets `=1`, and our params are appended after, so last wins.
- `hardware.xpadneo.enable` plus `SDL_JOYSTICK_HIDAPI_XBOX=0`; SDL's hidapi backend grabs the
  raw hidraw node and waits for native Xbox protocol that xpadneo never sends.
- brscan4's `.so` has hardcoded `/etc/opt/brother` paths and nixpkgs only wraps the CLI.
- `nix-settings.nix` centralised caches and GC; `allowUnfree` centralised in `flake.nix`.
