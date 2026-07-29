# Session Log

## Session: 2026-07-29

### Changes Made
- `packages/ghidra-reva.nix`: new. Ghidra 12.1 (`ghidra-bin` overrideAttrs) + ReVa v7.3.0.
- `modules/packages-desktop.nix`: `ghidra` → `ghidra-reva`.
- `modules/workstation.nix`: `~/projects/re/.mcp.json` + `~/projects/re/.claude/settings.json`.

### Decisions
- **Pinned Ghidra to 12.1, not 12.1.2.** Ghidra validates an extension's
  `extension.properties` `version=` against the running application version and rejects a
  mismatch. ReVa ships one prebuilt zip per supported Ghidra release; v7.3.0 covers 12.0,
  12.0.1–12.0.4 and 12.1 only. nixpkgs master is already on 12.1.2, for which no ReVa asset
  exists — so tracking nixpkgs here would silently disable the extension. **Bump the Ghidra
  version and the ReVa version together, and only to a pair that upstream ships.**
- **Overrode `ghidra-bin`, not `ghidra`.** `ghidra-bin` is a fetchzip of the NSA release, so
  a bump is a URL + hash edit; the source-built `ghidra` carries a gradle dependency lock
  (`deps.json`) that would need regenerating. Consequence: nixpkgs' `ghidra.withExtensions` /
  `buildGhidraExtension` framework is unavailable (it depends on nixpkgs' `NIX_GHIDRAHOME`
  patch, which exists only on the source build), hence the extension is unzipped by hand.
- **Extension installed in `postFixup`, not `postInstall`.** `ghidra-bin`'s `installPhase` is
  a custom phase with no `runHook postInstall`, so a `postInstall` attribute never executes —
  a silent no-op, not an error. `postFixup` appends to ghidra-bin's own, which creates
  `$out/bin` and wraps `support/launch.sh` with openjdk21 (12.1 wants JDK >= 21, still fine).
- **MCP registered project-scope, not `claude mcp add --scope user`.** User scope lives in
  `~/.claude.json`, which Claude Code rewrites itself; home-manager should not contend for it.

### Known Issues
- Enabling "ReVa Application Plugin" (Project view) and "ReVa Plugin" (CodeBrowser, then
  Save Tool) is per-user GUI state under `~/.config/ghidra` — cannot be declared, must be
  clicked once after the first launch.
- `~/projects/re/.mcp.json` is a read-only store symlink; a second MCP server for that
  workspace means editing `modules/workstation.nix`.
- Headless mode (`mcp-reva`, the `reverse-engineering-assistant` Python distribution) is
  not packaged — GUI/assistant mode only.

## Session: 2026-07-28

### Changes Made
- `modules/minecraft-server.nix`: new. Vanilla declarative server, `/var/lib/minecraft`.
- `modules/minecraft-couch.nix`: new. Bluetooth + xpadneo, MAC-keyed udev symlinks,
  bubblewrap per-player wrapper, `minecraft-couch@` VT session unit, generated Hyprland
  config, `hyprctl`-driven window placement, four `makeDesktopItem` entries,
  `minecraft-couch-sync`.
- `hosts/hydrogen.nix`: imported both; 25565 on `br0`; performance governor; lid ignored;
  `hardware.nvidia.package` pinned to `production`; `enable32Bit`.
- `modules/backup.nix`: `/var/lib/minecraft` in `backupPaths` + world-flush hooks.
- `users/sheath.nix`: `input` group.
- `docs/minecraft.md`: new runbook.

### Spec vs. reality
The design spec (`~/Downloads/specification.md`) targets "an HP ZBook" — that is hydrogen.
Four of its assumptions did not survive contact with this repo:

- **"Scope 25565 to wg0."** hydrogen has no wg0. The hub is on the router and remote peers
  route to hydrogen's LAN address, so tunnel traffic arrives on `br0`. One `br0` rule
  covers LAN + tunnel; the internet stays blocked because the router forwards only 51820.
- **"Pin `hardware.nvidia.package` to a 580 legacy branch."** No `legacy_580` attribute
  exists in nixos-25.11, and `stable`/`latest`/`beta`/`production` are *all* 580.142
  already. Pinned to `production` as drift insurance rather than as a fix.
- **AuthMe in the client mod stack.** AuthMe lets an *online* account log into an offline
  launcher; every couch client is an offline account on an `online-mode=false` server, so
  it does nothing here. Dropped — which removes the version-compatibility laggard the spec
  itself flags as gating the Minecraft version choice.
- **A nested compositor for the couch session.** Mutter cannot fullscreen a nested
  compositor's window, and GNOME must keep running (RustDesk capture). Replaced with a real
  logind session on tty7.

### Decisions
- **Separate VT over nesting.** `PAMName=login` + `TTYPath=/dev/tty7` makes logind register
  the unit as a real session, which is what lets Hyprland take DRM master when the VT goes
  active; GNOME goes inactive and releases it. Native DRM, no double compositing. Tradeoff:
  this is the one unvalidated piece — this box has a bad history with DRM/capture paths
  (gnome-remote-desktop, Sunshine). Fallback documented in `docs/minecraft.md`: nest inside
  `gamescope -f`, which *can* request fullscreen from Mutter where Hyprland cannot. Only the
  session script and unit would change.
- **Explicit `hyprctl` placement over the dwindle layout.** Dwindle splits the focused
  window, so four clients tile as "left half + three stacked", not quadrants. Placing each
  window by address as it maps is deterministic regardless of JVM start order and makes the
  1/2/3-player layouts fall out of the same code.
- **Four Prism data dirs.** Prism's single-instance lock is
  `ApplicationId::fromPathAndVersion(dataPath, version)` — verified in upstream
  `launcher/Application.cpp`. Without distinct `--dir` values the second `--launch` is
  handled by the *first* launcher process, which spawns the game outside the second
  sandbox and every character moves in unison. `minecraft-couch-sync` symlinks the shared
  trees so this is not four copies and mods are still installed once in the GUI.
- **Warning, not assertion, for placeholder controller MACs.** The server half must deploy
  while the pads are being paired.
- **`--offline` + `--server` on the Prism command line**, so no child touches an account
  picker or a multiplayer menu.

### Bugs caught before deploy
- udev rejected the whole ruleset: a trailing `# comment` on a rule line is a syntax error
  (`udevadm verify` runs at build time — `Invalid key/value pair`). Comments moved above.
- The borg world-flush hook was silently a no-op. `lib.escapeShellArg` applied to the
  command alone and then hand-quoted inside `sh -c '…'` produced
  `sh -c 'echo 'save-all flush' > fifo'`, which the outer shell splits into two arguments;
  sh takes the second as `$0`, the redirection never happens. Now the entire inner script
  is escaped once as a unit.

### Known Issues / Next
- **Nothing is deployed or runtime-tested.** `nix build` of hydrogen's toplevel passes on
  sulphur; that is all. The VT handoff, controller isolation and frame pacing are all
  untested on the real machine.
- Controller MACs are placeholders — `bluetoothctl devices` on hydrogen, then rebuild.
- The Prism instance does not exist yet; `docs/minecraft.md` §"First-time setup" is the
  runbook.
- Off-tunnel closed-port check for 25565 not yet performed.
- Offline mode means all four players are Steve/Alex. Real usability problem with four kids
  on one screen; nameplate legibility at quarter-screen needs checking.

## Session: 2026-07-22

### Changes Made
- `modules/ollama.nix`: new. `services.ollama` with `pkgs.ollama-cuda` on loopback, serving
  `qwen2.5:7b` via `loadModels`. Includes `nixpkgs.config.cudaCapabilities = [ "6.1" ]`.
- `modules/paperless-gpt.nix`: new. Podman OCI container `icereed/paperless-gpt:v0.27.0`,
  host networking, sops `paperless-gpt-token`, state under `/var/lib/paperless-gpt`.
- `hosts/hydrogen.nix`: imported both modules.
- `modules/backup.nix`: added `/var/lib/paperless-gpt` to `backupPaths`.
- `secrets/secrets.yaml`: added `paperless-gpt-token` (env file: `PAPERLESS_API_TOKEN=...`).

### Diagnosis: ollama ran on CPU despite ollama-cuda
Everything at the NixOS layer was correct -- driver healthy (`nvidia-smi` OK), the systemd
unit had `DeviceAllow` for the nvidia char devices, `LD_LIBRARY_PATH` included
`/run/opengl-driver/lib` + the cuda 12.8 runtime, and `libggml-cuda.so` was present and
`ldd`-clean. Yet startup logged `total_vram="0 B"`, CPU-only. With `OLLAMA_DEBUG=1` the probe
showed the real cause: `verifying if device is supported ... compute=6.1` immediately
followed by `filtering device which didn't fully initialize ... library=CUDA`. The card was
detected but ggml-cuda had no kernels for it.

Root cause in nixpkgs' cuda capability DB (`_cuda/db/bootstrap/cuda.nix`): capability `6.1`
has `dontDefaultAfterCudaMajorMinorVersion = "12.3"`, and the toolkit is 12.8, so Pascal is
not in the default gencode set -- `ollama-cuda` compiled for sm_75+ only. Fix:
`nixpkgs.config.cudaCapabilities = [ "6.1" ]` (6.1 is still *supported* by 12.8; NVIDIA drops
Pascal only in CUDA 13). Post-fix: `total_vram="8.0 GiB"`, model 100% in VRAM (4830 MiB,
`size_vram == size`), ~33 tok/s on an invoice-classification prompt returning clean JSON.

### Decisions
- **GPU over CPU** (user choice). CPU inference worked out of the box and is adequate for
  async classification, but the user opted to use the P4200. Tradeoff accepted: the
  non-default sm_61 arch means from-source `ollama-cuda` rebuilds on every nixpkgs bump,
  absorbed by the nightly auto-update.
- **podman scoped in the module**, not via importing `modules/virtualisation.nix` (which is
  desktop-flavoured and used only by sulphur/osmium).
- **Bind mounts owned 10001:10001** (the image's default PUID/PGID under rootful podman)
  rather than named volumes, so borg can point at `/var/lib/paperless-gpt` directly.
- **Deploy via build-on-hydrogen**, not `nix copy`: sheath is not a trusted daemon user on
  hydrogen and root ssh is disabled, so pushing the closure fails the signature check. The
  same locked flake yields an identical derivation built locally.

### Known Issues / Next
- **Live classification not yet run.** ollama GPU path and paperless-gpt<->paperless auth are
  both verified independently, but no document has been tagged `paperless-gpt-auto` end to
  end -- it mutates real metadata, left to the user to drive.
- A `paperless-gpt-failed` tag already existed in paperless before this deploy (26 docs);
  something ran paperless-gpt here previously. Not investigated.

## Session: 2026-07-21

### Changes Made
- `modules/impermanence-server.nix`: added `fileSystems."/persist".neededForBoot = true;`
  next to the existing `sops.age.keyFile` override, with a comment explaining the initrd
  activation ordering and the self-concealing nature of the failure.
- `docs/CHANGELOG.md`: `### Fixed` entry for the above.
- `docs/SESSION_LOG.md`: created (prescribed by `CLAUDE.md` but previously absent).

### Context
Started as a scoping exercise for local-LLM document classification on paperless (see
"Known Issues" below). Checking paperless' health turned up an active outage instead.

### Diagnosis
`systemctl --failed` on hydrogen showed `paperless-scheduler`, `nextcloud-setup`, and
`acme-order-renew-luckyobserver.com` failed, with `paperless-web`/`paperless-consumer` dead
on dependency failure. All shared one cause: `/run/secrets` did not exist.

Boot journal:

    14:42:35  sops-install-secrets: cannot read keyfile '/persist/secrets/age-keys.txt'
    14:42:35  Activation script snippet 'setupSecrets' failed (1)
    14:42:38  systemd[1]: Mounted /persist.

The key file itself was intact (264 bytes, Jun 15) -- only unreachable at that moment.
`hardware/hydrogen.nix:34` declared `/persist` without `neededForBoot`, and that file is
generated by `nixos-generate-config`, so the fix belongs in the impermanence module.

Same error on boots -1, -2, -3 (Jul 21 11:01, Jul 20, Jul 15). It went unnoticed because
eight generations were built that day (09:56-14:33) and each `nixos-rebuild switch` re-ran
activation post-mount, repairing `/run/secrets`; gen 19 at 11:25 is immediately followed by
`acme-success` at 11:26. The Jun 15 -> Jul 15 uptime was 29 days, which is why nothing
surfaced earlier.

### Decisions
- **`neededForBoot` over `sops.age.sshKeyPaths`.** The host ed25519 key is already
  auto-imported as an age identity (`age1jv89wl...`), so pointing sops at it would sidestep
  `/persist` entirely and is arguably more robust. Rejected for this fix: it requires
  re-encrypting `secrets/secrets.yaml` to add a recipient, which touches the shared secret
  store for all four hosts. `neededForBoot` is one line and is the documented
  impermanence + sops-nix pattern. Worth revisiting if `/persist` ordering bites again.
- **Verified across a real reboot, not a rebuild.** A rebuild masks this class of bug by
  construction, so a green `nixos-rebuild switch` proves nothing here.

### Verification (post-reboot, 15:25)
- Boot journal: no `cannot read keyfile` for `/persist`, no `setupSecrets failed`.
- `/run/secrets` populated with all five system secrets.
- `systemctl --failed`: 0 units.
- paperless-{web,consumer,scheduler,task-queue}, nginx, immich, calibre-web, postgresql,
  syncthing all active; `nextcloud-setup` `Result=success`.
- `paper`/`nc`/`calibre` return 302, `immich` 200 over HTTPS.

### Known Issues
- **User-level sops still fails on hydrogen**: `sops-nix.service` (home-manager) cannot read
  `/home/sheath/.config/sops/age/keys.txt` -- the file does not exist. Separate from the
  system-level outage and unrelated to `/persist`; only affects the pi/openwebui config.
  Not addressed.
- **Borg not yet re-verified.** Both jobs were victims of the outage; the secrets are now
  present but neither has run since. Next scheduled trigger 03:00.
- **Deferred: local-LLM document classification for paperless.** Plan researched but not
  implemented -- `services.ollama` with `package = pkgs.ollama-cuda` (note:
  `services.ollama.acceleration` was REMOVED in the pinned nixpkgs) serving `qwen2.5:7b`,
  plus `icereed/paperless-gpt` v0.27.0 as a podman container on `--network=host`. Requires
  a paperless API token generated by hand in the UI and stored in sops. paperless-ngx's own
  built-in AI is 3.0-beta-only, absent from nixpkgs, and is manual-click rather than
  auto-tagging; `clusterzx/paperless-ai` is abandoned. Hydrogen's P4200 (8 GB, Pascal
  SM 6.1) has no Flash Attention, so KV cache stays f16 -- budget VRAM for a 7B Q4_K_M.
