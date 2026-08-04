# Changelog

## [Unreleased]
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
