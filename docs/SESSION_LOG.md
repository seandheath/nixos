# Session Log

## Session: 2026-07-30

### Changes Made
- `modules/opencode.nix`: new. `pkgs.opencode` + a sops-templated
  `~/.config/opencode/opencode.json` (provider `vllm`, `mcp.reva`, `agent.re`) + a plain
  `~/.config/opencode/re-instructions.md` holding the RE system prompt.
- `modules/workstation.nix`: imports `./opencode.nix`.
- `home/sheath.nix`: pi's `contextWindow` 32768 → 262144, `maxTokens` 8192 → 32768.
- `packages/qwen-code.nix`: new. qwen-code 0.21.1 repacked from the npm registry tarball.
- `modules/qwen-code.nix`: new. That package + a plain `~/.qwen/settings.json`, a plain
  `~/.qwen/QWEN.md` (RE instructions), and a sops-templated `~/.qwen/.env` (the secrets).
- `modules/workstation.nix`: also imports `./qwen-code.nix`.
- `prompts/re-agent.md`: new (new top-level dir). Canonical RE agent instructions.
- `packages/re-container.nix`, `modules/re-container.nix`: new. Sandboxed `cqwen`/`copencode`.
- `modules/workstation.nix`: also imports `./re-container.nix`.
- `modules/opencode.nix`, `modules/qwen-code.nix`: inline prose replaced with
  `source = ../prompts/re-agent.md`; keep-in-step comments replaced with a pointer to it.

### Decisions
- **Scoped the work to the client half.** The spec describes Ghidra+ReVa, OpenCode and
  vLLM. ReVa landed 2026-07-29; vLLM is an existing *remote* endpoint. Only OpenCode was
  actually missing from the repo.
- **vLLM will never be a service here.** hydrogen's P4200 is Pascal (SM 6.1) and vLLM
  requires compute capability >= 7.0; nixos-25.11 has no `services.vllm` module either.
  sulfur's RTX 5080 has the capability but only 16 GB, and a CUDA `vllm` build is not in
  the binary cache. Do not re-propose this.
- **Reused the `openwebui-*` sops trio rather than adding `vllm-*` keys.** Sean's choice.
  Worth knowing what those secrets actually point at: `openwebui-url` is
  `https://<host>/api` — Open WebUI's OpenAI-compatible root — proxying to the vLLM host,
  not vLLM's `/v1` directly. Provider id is still `vllm` since that is what serves tokens.
- **Verified tool calling survives the Open WebUI proxy** before committing to that path,
  since spec §6's headline failure is "model ignores tools" and a proxy that drops the
  `tools` array would produce exactly that. A `/chat/completions` carrying a `tools` array
  came back `finish_reason=tool_calls` with well-formed arguments. It works.
- **Whole-file sops template, not `xdg.configFile` + env interpolation.** OpenCode does
  support `{env:…}`/`{file:…}` substitution, so the token alone could have stayed out of
  the store — but the base URL and the served model id are also secrets, and the model id
  has to be a JSON *object key* (`provider.vllm.models.<id>`). Templating the whole file
  handles all three uniformly; the id is emitted via a dynamic Nix attribute name and sops
  substitutes every occurrence, including the two inside `model`/`small_model`.
- **`re-instructions.md`, not `AGENTS.md`.** OpenCode auto-loads a global
  `~/.config/opencode/AGENTS.md` into every session. Using that name would push
  "never bulk-decompile" into ordinary coding sessions *and* double-include it alongside
  `agent.re.prompt`. A non-magic filename referenced explicitly scopes it to RE work.
- **`limit.output = 32768`, not 8192.** vLLM enforces only
  `max_tokens <= max_model_len`, so output is a client-side reservation drawn from the same
  262144 window rather than a discoverable server value. The served model reasons before
  answering (a 74-character reply cost 384 completion tokens), so an 8k cap risks
  truncating mid-tool-call — spec §6's "truncated / malformed tool calls". 32768 still
  leaves ~229k for context.

- **Hex arithmetic: no ReVa tool for it, so the agent shells out.** The `re` agent was
  getting stuck computing hex offsets by hand (on `/bl31`, an AArch64 ATF dump — address
  math everywhere). Enumerated ReVa 7.3.0's MCP surface against the live endpoint:
  **88 tools, none of them a calculator**. `run-script` looked like the in-Ghidra escape
  hatch, but it is **unavailable on this install** — it returns "Ghidra was not started
  with PyGhidra. Python is not available", because `packages/ghidra-reva.nix` wraps the
  stock `support/launch.sh` rather than `pyghidra-gui`. So the fix is two-part:
  1. `re-instructions.md` tells the model to shell out to `python3 -c 'print(hex(…))'` and
     never compute mentally, and states that `run-script` is dead so it stops retrying it.
  2. `agent.re.permission.bash` pre-approves exactly `python3 -c *` (everything else stays
     `ask`). Instructing the model to shell out is useless if each call blocks on a
     confirmation — it would go back to guessing.
  Also steers toward the tools that make the math unnecessary at all, which is the larger
  win: `get-structure-info`/`parse-c-structure` for field offsets, `analyze-vtable` for
  slots, `find-cross-references`/`get-call-graph` for branch targets, `trace-data-flow-*`
  for provenance, `get-memory-blocks` for the real image base.
- **ReVa's bundled `AGENTS.md`/`CLAUDE.md` are not usable as agent instructions.** They
  document how to *build ReVa itself* (gradle, JUnit, Java 21 style rules), not how to
  drive it. Don't wire them in.

- **qwen-code added as a second RE client, packaged out of nixpkgs.** `pkgs.qwen-code` is
  **0.2.2**; upstream stable is **0.21.1**. Probing both bundles: 0.2.2 has no
  `modelProviders`, no `permissions`, no `context.fileName`, and configures providers only
  through `OPENAI_BASE_URL`/`OPENAI_MODEL` env vars. Every key this deployment needs
  postdates it, so the nixpkgs version was not usable and `packages/qwen-code.nix` repacks
  the npm tarball instead. That tarball is fully pre-bundled — zero runtime `dependencies`,
  no native modules, a **static-pie** vendored ripgrep — so it is an unpack + `makeWrapper`
  over `nodejs_22`, with no `npmDepsHash` to churn on bumps.
- **Do not trust qwen-code's published settings docs; the binary disagrees.** Everything
  below was established by round-tripping real config through 0.21.1, not from the docs
  site, which is written against a schema the binary migrates *away from*:
  - `modelProviders.<id>` is a bare **array** of model entries. The documented
    `{ protocol, models: [...] }` wrapper is silently discarded on load.
  - The SDK protocol comes from a separate top-level `providerProtocol` map
    (`{ "vllm": "openai" }`). Omit it and the models are dropped with "provider … is not a
    built-in protocol". A provider *named* `openai` would also work, since the id falls back
    to itself as the protocol, but `vllm` + the explicit map is clearer.
  - `generationConfig` (`contextWindowSize`, `samplingParams`) belongs on the **model
    entry**. Under top-level `model` it is accepted and ignored, with a warning saying so.
  - MCP transport is chosen by key name: `httpUrl` → `StreamableHTTPClientTransport`,
    `url` → SSE. ReVa needs `httpUrl`.
  - Permission rules must say `run_shell_command(...)`. The schema's own description
    advertises `"Bash(git *)"` and `TOOL_NAME_ALIASES` maps `Bash` → `run_shell_command`,
    but tested against the approval path, **every `Bash` form still prompts** — bare and
    parenthesised alike — while `run_shell_command` and `ShellTool` both work. Scoping does
    hold: under `run_shell_command(python3 -c *)`, a `touch` still prompts.
- **Secrets go in `.env`, not the sops-templated config — the reverse of OpenCode/pi.**
  qwen-code rewrites its own `settings.json` on startup (schema migration + a `$version`
  stamp). Tested against a 0400 sops symlink, that write **replaces the symlink with a
  regular 0644 file**, so a templated API key would be copied out of the tmpfs-backed sops
  store into a world-readable file in `$HOME` on first run. This is exactly the hazard the
  previous entry's Known Issues flagged in the abstract, now with a tool that triggers it.
  Fix: `settings.json` ships secret-free with `$VAR` placeholders (resolved via
  `resolveEnvVarsInObject`), and only `~/.qwen/.env` — the first candidate qwen-code's
  `findEnvFiles()` checks, and a file it reads but never writes — comes from sops. Verified
  the rewrite leaves the placeholders unresolved, so no secret reaches the rewritten file.
- **Sandboxed the RE agents, because they are the ones that most need it.** Both are driven
  by a remote model and handed a shell tool; uncontained they reach SSH keys, GPG and this
  config. `cclaude` already solves this shape for Claude Code, so `cqwen`/`copencode` reuse
  its security flags verbatim rather than inventing a posture.
- **`--network=pasta:-T,8080` is the whole trick, and it took three attempts to find.**
  ReVa binds loopback only, so the obvious routes fail: `host.containers.internal` is
  pasta's gateway (169.254.1.2) and 8080 there is unreachable; `--map-guest-addr` did not
  work either. pasta's `-T` forwards the *container's* localhost to the *host's*. Measured
  inside the container: 8080 reachable, 8384 and 631 blocked, outbound 443 + DNS to the vLLM
  endpoint fine. Strictly better than `--network=host`, which reaches ReVa by exposing every
  host-local service. The unobvious payoff: because it is the container's *own* localhost
  that forwards, `http://localhost:8080/mcp/message` works unchanged, so there is no
  container-specific config to keep in step with the host's.
- **dockerTools image, not a Containerfile.** cclaude uses debian + curl-to-bash because
  that is how Claude Code ships. Both agents here are already Nix packages, so building the
  image from them is reproducible, needs no build-time network, and cannot drift from what
  `qwen`/`opencode` are on the host. Dropped cclaude's `/nix/store` mount and nix daemon
  socket (Sean's call) so the agent can execute only what is in the image, and dropped SSH
  agent forwarding outright.
- **Two things bit during implementation, both worth remembering:**
  - A tmpfs `$HOME` — chosen so secrets could never persist — does not work. Podman's
    `--tmpfs` rejects `uid=`, so the mount lands owned by the namespace root and the uid-1000
    agent cannot write to it. Fell back to cclaude's named volume with `,U`. To keep secrets
    out of that volume anyway, the three endpoint values are passed as **environment
    variables** rather than a mounted `.env`; qwen-code resolves settings.json's
    `$OPENWEBUI_*` placeholders from the process environment identically (verified).
  - OpenCode's config bakes `{file:<absolute host path>}` for the agent prompt and resolves
    it literally, so config load fails outright inside the container until that exact path
    exists. The prompt is mounted at the host path — the one host-shaped path in the
    container, a single read-only file. Worth knowing if `home.homeDirectory` ever changes.
- **All 88 ReVa tools are auto-approved, in both clients — and that is now a decision, not a
  gap.** Found by probing rather than reading config: each agent was asked to attempt a real
  `delete-structure`, and both dispatched it with no confirmation. The 14 write tools
  (`set-comment`, `create-label`, `rename-variables`, `apply-data-type`, `delete-structure`,
  `write-script`, …) are all in scope. The trap here is assuming the narrow `python3 -c`
  allow-rules cover it: **MCP is a different code path from the shell tool**, so those rules
  gate bash and do nothing for ReVa.
  Sean's call: unrestricted ReVa is the point of the tool, and prompting on every retype
  would cost more than the risk. Two consequences recorded in the module rather than
  rediscovered later: the container gives *zero* protection to the Ghidra database, and the
  only surviving control is procedural, so `prompts/re-agent.md` now tells the agent outright
  that nothing will stop it and that confirming the project is a copy is on the analyst.
  If it is ever revisited, both gating syntaxes are already worked out — qwen-code builds
  `mcp__<server>__<tool>` rule names, OpenCode's permission schema is
  `.catchall(PermissionRule)` with ReVa's tools named `reva_<tool>`.
  Related, and not currently exploitable: `write-script` drops a file into the Ghidra
  project, but `run-script` is dead on this install (stock launcher, no PyGhidra). That is a
  property of `packages/ghidra-reva.nix`'s launcher, **not** a designed boundary — it would
  stop holding silently if that ever moved to a PyGhidra launch.
- **One canonical RE prompt, because "keep them in step" already failed.** Both modules
  inlined their own copy with a comment telling future-us to sync them by hand. Diffing the
  two *deployed* files after a single session found they had already diverged twice. Now
  `prompts/re-agent.md` is the only copy and both modules `source` it.
  - **No per-client templating turned out to be necessary**, which is why this is a plain
    `.md` and not a Nix function or a `substituteAll`-style template. Only two things
    differed: a sentence about the install being RE-only (true of both clients at the point
    either reads the file) and a mention of the shell tool *by name*. The latter is the one
    real constraint on the canonical file — OpenCode's is `bash`, qwen-code's is
    `run_shell_command` — so the text says "shell out to python3" and lets each model use
    whatever its own tool is called. Both module comments now say this.
  - Chose a new top-level `prompts/` dir over `docs/`: this is live config data that ships
    to two clients, and burying it among CHANGELOG/SESSION_LOG invites an edit that
    silently changes agent behaviour.
- **The "there is no source tree" claim was wrong and is now fixed.** Sean sometimes opens
  the agent inside source that is *representative* of the binary — upstream project, SDK,
  vendor drop, a different version of the same component — specifically to give it hints.
  The instructions asserted the opposite, which would have led an agent to ignore material
  deliberately put in front of it. New "Reference source" section frames it as hint-not-
  answer: good for names, struct/enum layouts, constants and algorithm shape (which survive
  version drift and are expensive to recover from a binary), untrustworthy for anything
  checkable, because the version may differ, the compiler restructures (inlining,
  unrolling, tail merging, layout, dead-code removal), and ifdefs/feature flags may mean a
  branch was never compiled in. Rule: hypothesis from source → confirm against binary →
  attribute which is which → binary wins on conflict, and the conflict is itself a finding.
  Also threaded into two existing sections: grepping source beats decompiling for locating
  things (context budget), and source names are the best rename source but must be matched
  on evidence first, since a wrong name gets believed later (write operations).
- **Arithmetic guidance widened past hex addition.** It named only offsets, page
  boundaries, field offsets and hex/dec conversion; a model does not read that as covering
  "is bit 12 set" or "what is this as a signed int". Now covers masks/flag tests, shifts
  and rotates, signed/unsigned and sign extension, endianness, and float/int
  reinterpretation, each with a `python3 -c` one-liner **verified by running it** before
  shipping. Stated the reason they matter more than a bad sum: a wrong address is usually
  obviously out of range, whereas a wrong sign extension or byte swap is plausible and
  survives review. (While checking the examples I got the expected value for the 12-bit
  sign-extension case wrong myself — the one-liner was right — which is the section's
  own argument, made accidentally.)
- **No permission change was needed for any of that.** Both clients' `python3 -c *` rules
  already admit `python3 -c 'import struct; …'`: a semicolon inside the quoted `-c`
  argument does not split the command for matching. Control-tested rather than assumed —
  a bare `touch` under `opencode run` blocks on an unanswerable confirmation and never
  creates its probe file, so the `import struct` case really is the rule matching and not
  non-interactive auto-approval. Both module comments record this, since narrowing the rule
  later would silently break the new guidance.
- **`QWEN.md`, not `QWEN_SYSTEM_MD`.** The global context file is *appended* to
  qwen-code's core system prompt as `userMemory`; `QWEN_SYSTEM_MD` **replaces** the base
  prompt entirely and would throw away its tool-usage and safety scaffolding. Since this
  install is RE-only (Sean's call), the RE prose can live in the always-loaded global
  context file — no equivalent of OpenCode's `re-instructions.md` scoping trick is needed.

### Known Issues
- `run-script` (and any future PyGhidra-dependent ReVa tool) is unavailable. Fixing it
  means making `packages/ghidra-reva.nix` launch through PyGhidra instead of
  `support/launch.sh`, which pulls a Python runtime into the Ghidra wrapper. Not attempted
  — `python3 -c` via OpenCode's bash tool covers the arithmetic case that motivated it.
- Home-manager sops `templates.<n>.path` installs a **symlink** into
  `~/.config/sops-nix/secrets/rendered/`, so `~/.config/opencode/opencode.json` is a
  symlink, not a regular file. Fine for OpenCode (it only reads), but any tool that
  rewrites the config in place would write through into the sops-managed store dir.
- `{file:…}` interpolation in `agent.<name>.prompt` is present in opencode 1.1.14's bundle
  but is not described in the JSON schema. If a future bump breaks it, inline the
  instructions text into `prompt` directly.
- `~/.qwen/settings.json` and `~/.qwen/QWEN.md` are home-manager files with `force = true`
  because qwen-code writes to both (schema migration; `/memory add`). Expect them to churn:
  qwen-code replaces the store symlink with a regular file between rebuilds, and activation
  restores the canonical version. Runtime changes made through `/auth` or the model picker
  therefore do not survive a `nixos-rebuild` — edit the module instead.
- `packages/qwen-code.nix` pins a version by tarball hash with no update script. Bumping is
  a version + `hash` edit, but **re-verify the settings schema after any bump**: the 0.2.2 →
  0.21.1 gap shows this project migrates its config format aggressively, and a silently
  dropped `providerProtocol` or `generationConfig` degrades quietly rather than erroring.

## Session: 2026-07-29

### Changes Made
- `packages/ghidra-reva.nix`: new. Ghidra 12.1 (`ghidra-bin` overrideAttrs) + ReVa v7.3.0.
- `modules/packages-desktop.nix`: `ghidra` → `ghidra-reva`.
- `modules/workstation.nix`: comment recording that ReVa's MCP registration is user-scope
  and intentionally not declarative.

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
- **MCP registered at user scope, in `~/.claude.json` — reversing an earlier decision.**
  First attempt declared a project-scope `~/projects/re/.mcp.json` from home-manager, to keep
  the registration in nix and out of Claude Code's mutable state. It did not survive contact:
  `.mcp.json` applies only to the directory `claude` is launched from, but ReVa is one
  localhost endpoint acting on whatever program Ghidra has open — not per-project. The real
  workflow is a session in `~/workspace/android-stuff/arm-trusted-firmware` reading ATF source
  *and* driving Ghidra to port symbols into a BL31 dump; a `~/projects/re`-pinned registration
  forced a `cd` away from the source to reach the decompiler. Declarativeness buys little here
  anyway — the endpoint is localhost-only and inert without Ghidra running on the same box.

### Known Issues
- Enabling "ReVa Application Plugin" (Project view) and "ReVa Plugin" (CodeBrowser, then
  Save Tool) is per-user GUI state under `~/.config/ghidra` — cannot be declared, must be
  clicked once after the first launch.
- ReVa's registration lives in `~/.claude.json`, so it does not follow to another machine;
  re-add with the `claude mcp add` line in `modules/workstation.nix`.
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
