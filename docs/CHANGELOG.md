# Changelog

Also the decision log. Rationale that would otherwise bloat a code comment lives here.

## Open

- **Nextcloud 32 → 33 on hydrogen.** Declaring `nextcloud33` *is* the upgrade and it
  migrates the live schema; Nextcloud refuses multi-major jumps. Wants a Borg restore point
  and a window. Currently healthy at 32.0.13, `needsDbUpgrade: false`.
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

## 2026-08-14

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
