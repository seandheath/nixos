# Changelog

## [Unreleased]
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
