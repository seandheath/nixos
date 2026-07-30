{ pkgs, ... }:

# OpenCode wired to the remote vLLM and to Ghidra's ReVa MCP server: the client half
# of the agentic reverse-engineering stack (docs/specification.md in ~/Downloads).
#
# Divison of labour:
#   packages/ghidra-reva.nix  Ghidra 12.1 + ReVa 7.3.0, MCP over streamable HTTP on
#                             localhost:8080 (installed via packages-desktop.nix)
#   this module               OpenCode (the agent loop) + its provider/MCP config
#   <remote>                  vLLM, fronted by Open WebUI. Not managed here at all.
#
# Why vLLM is not a NixOS service anywhere in this flake, so it stops being re-proposed:
# the only always-on GPU box is hydrogen, whose Quadro P4200 is Pascal (SM 6.1), and vLLM
# hard-requires compute capability >= 7.0 (vllm-project/vllm#1431, #963 — still enforced on
# mainline as of 2026-06). nixos-25.11 also ships no `services.vllm` module. Inference
# therefore stays remote and is consumed purely as an OpenAI-compatible endpoint.
#
# Imported from workstation.nix, which *is* the host gate: hydrogen never evaluates this,
# so unlike home/sheath.nix's `enablePi` there is no hostname test to keep in sync.
{
  environment.systemPackages = [ pkgs.opencode ];

  # Operating constraints from the spec, as the RE agent's system prompt.
  #
  # Deliberately NOT named AGENTS.md: OpenCode auto-loads a global
  # ~/.config/opencode/AGENTS.md into *every* session, and "never bulk-decompile" is
  # noise in an ordinary coding session (and would then be included twice, once
  # globally and once via agent.re.prompt). A non-magic filename referenced explicitly
  # from agent.re.prompt scopes it to RE work only.
  home-manager.users.sheath.xdg.configFile."opencode/re-instructions.md".text = ''
    # Reverse engineering with ReVa

    You are driving Ghidra through the ReVa MCP server. ReVa acts on whichever program
    Ghidra currently has open — you cannot switch programs, and you are not browsing a
    filesystem.

    ## Context budget

    Retrieve functions **individually**. Never request bulk decompilation of a binary:
    a single large function can consume tens of thousands of tokens, and decompiler
    output is by far the dominant consumer of the context window. Locate first
    (symbol/xref/string search), then decompile only the specific function you need.

    If you catch yourself about to iterate over a function list decompiling each entry,
    stop and narrow the search instead.

    ## Arithmetic: shell out, never compute in your head

    You are bad at hex arithmetic and you will get it wrong silently. Do not compute
    address offsets, page boundaries, struct field offsets, or hex/decimal conversions
    mentally or by "reasoning through" them. Shell out:

        python3 -c 'print(hex(0x40000000 + 0x1a2b8))'

    That exact form is pre-approved and will not prompt. Use it freely — one shell call is
    vastly cheaper than a wrong address that sends you down a dead branch.

    ReVa itself has **no calculator tool**, and its `run-script` tool cannot help: it
    requires Ghidra to have been launched via PyGhidra, and this install uses the stock
    launcher, so every call returns "Python is not available". Do not keep retrying it.

    ## Prefer the tools that make arithmetic unnecessary

    Most hex arithmetic in this workflow is avoidable — ReVa will compute it for you and
    be right. Reach for these before doing any math at all:

    - Struct field offsets — `get-structure-info`, `parse-c-structure`, `list-structures`.
      Never hand-sum field sizes to find an offset.
    - Vtable slots — `analyze-vtable`, `find-vtables-containing-function`,
      `find-vtable-callers`. Never multiply an index by pointer size yourself.
    - Branch and call targets — `find-cross-references`, `get-call-graph`, `get-call-tree`,
      `get-callers-decompiled`, `get-referencers-decompiled`, `resolve-thunk`. Never decode
      a relative branch displacement by hand.
    - Where a value comes from or goes — `trace-data-flow-backward`,
      `trace-data-flow-forward`, `find-variable-accesses`.
    - Load addresses and segment bounds — `get-memory-blocks`. Never assume an image base;
      on AArch64 firmware images it is frequently not what you would guess.
    - A specific constant — `find-constant-uses`, `find-constants-in-range`,
      `list-common-constants`. Search for it rather than deriving it.
    - Bytes or data at an address — `read-memory`, `get-data`.

    If you find yourself about to write out an addition in prose, that is the signal to
    call one of the above instead.

    ## Write operations

    ReVa can rename symbols and set types in the **live** program — these are real edits
    to the analyst's database, not a scratch buffer. Before applying a batch of renames,
    confirm the open project is a copy rather than the primary one. Prefer one rename at
    a time with a stated justification over speculative bulk renaming.

    ## Single-program scope

    Multi-binary work needs a separate session per binary (or headless Ghidra). Do not
    assume symbols from one binary are visible while another is open.

    ## Malformed tool calls

    If your tool calls come back rejected, that is an inference-side problem (tool-call
    parser or quantization on the vLLM host), not something to work around by pasting
    JSON into prose. Report it and stop.
  '';
  home-manager.users.sheath.xdg.configFile."opencode/re-instructions.md".force = true;

  # ~/.config/opencode/opencode.json, rendered from sops at activation.
  #
  # The whole file is one sops template rather than a plain xdg.configFile because all
  # three of the endpoint's identifying details are secrets (base URL, served model id,
  # token) and sops.templates renders whole files — same reasoning and same shape as the
  # pi-models.json template in home/sheath.nix. Nothing model-identifying lands in the
  # (public) flake or the nix store.
  #
  # Imported as a sub-module rather than assigned by attr path so that `config` here is
  # home-manager's, not the NixOS one: `config.sops.placeholder` only exists inside the
  # home-manager sops module's own evaluation. Same trick as workstation.nix's
  # claudeSettings activation script; `imports` is a list option, so both definitions of
  # home-manager.users.sheath.imports merge.
  home-manager.users.sheath.imports = [ ({ config, ... }: {
    # Re-declared here rather than leaning on home/sheath.nix's pi block, so this feature
    # stands alone if pi is ever dropped. Identical sops.secrets submodule definitions
    # merge cleanly. `defaultSopsFile` and `age.keyFile` are NOT re-declared — those are
    # set once in home/sheath.nix for every non-hydrogen host.
    sops.secrets."openwebui-url" = { };
    sops.secrets."openwebui-model" = { };
    sops.secrets."openwebui-api-key" = { };

    sops.templates."opencode.json" = {
      path = "${config.home.homeDirectory}/.config/opencode/opencode.json";
      content = builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";

        # Custom provider: the served model is not in the models.dev catalog, so OpenCode
        # needs both the SDK to load (`npm`) and the model's capabilities spelled out.
        # @ai-sdk/openai-compatible@1.0.{29,30} is already inside the nixpkgs opencode
        # closure (lib/opencode/node_modules/.bun), so this resolves offline — no bun
        # fetch on first run.
        #
        # The base URL in sops is Open WebUI's OpenAI-compatible root (…/api), which
        # proxies to the vLLM host; provider id stays `vllm` since that is what actually
        # serves the tokens. Tool calling through that proxy was verified end-to-end on
        # 2026-07-30 (a /chat/completions with a `tools` array came back
        # finish_reason=tool_calls with well-formed arguments), so spec §6's "model
        # ignores tools" failure does not apply to this path.
        provider.vllm = {
          npm = "@ai-sdk/openai-compatible";
          name = "vLLM (via Open WebUI)";
          options = {
            baseURL = config.sops.placeholder."openwebui-url";
            apiKey = config.sops.placeholder."openwebui-api-key";
          };
          # The model id is a *secret*, so it is used as a dynamic attribute name. Nix
          # accepts the opaque "<SOPS:…:PLACEHOLDER>" string as an attr name and sops
          # substitutes every occurrence at activation — including the two inside the
          # model/small_model strings below.
          models.${config.sops.placeholder."openwebui-model"} = {
            # Stated explicitly: without a models.dev entry OpenCode does not know the
            # model can call tools, and would never offer the ReVa tools to it.
            tool_call = true;
            limit = {
              # Mirrors the endpoint's advertised max_model_len, read from GET /models on
              # 2026-07-30 (262144). OpenCode compacts against this number, so setting it
              # above the server's real limit is spec §6's "context overflow mid-task".
              # Re-check whenever the served model or vLLM's --max-model-len changes.
              context = 262144;
              # Output is a *client-side* budget: vLLM enforces only
              # max_tokens <= max_model_len, with no separate output cap (probed
              # 2026-07-30 — 262000 was accepted, 300000 rejected with
              # "cannot be greater than max_model_len"). So this number is chosen, not
              # discovered, and it is reserved out of the same 262144 the prompt draws
              # from. 32768 rather than 8192 because the served model is a reasoning
              # model (a 74-character answer cost 384 completion tokens, ~310 of them
              # reasoning): reasoning over a large decompiled function then emitting a
              # tool call can run well past 8k, and hitting the cap mid-call is spec §6's
              # "truncated / malformed tool calls". Still leaves ~229k for context.
              output = 32768;
            };
          };
        };

        model = "vllm/${config.sops.placeholder."openwebui-model"}";
        # Title generation and other cheap side tasks. Only one model is served, so it is
        # the same one; split this out if a smaller model is ever added to the endpoint.
        small_model = "vllm/${config.sops.placeholder."openwebui-model"}";

        # ReVa. Note the path: the spec's §3.3 example says /mcp, but ReVa 7.3.0 actually
        # serves at /mcp/message on 8080 (see packages/ghidra-reva.nix). The endpoint only
        # responds while Ghidra has a program open, which is also why loopback is correct
        # and it is never bound externally.
        mcp.reva = {
          type = "remote";
          url = "http://localhost:8080/mcp/message";
          enabled = true;
        };

        # `opencode --agent re`, or Tab to switch into it. mode = "primary" makes it
        # selectable as the top-level agent rather than only as a subagent.
        agent.re = {
          description = "Reverse engineering against the program currently open in Ghidra/ReVa";
          mode = "primary";
          # {file:…} is interpolated by OpenCode at config load (verified present in
          # opencode 1.1.14's bundle). Keeping the prose in its own file means it stays
          # greppable and diffable in this repo instead of being buried in a JSON string.
          prompt = "{file:${config.home.homeDirectory}/.config/opencode/re-instructions.md}";
          # Pre-approve exactly the arithmetic escape hatch the prompt tells it to use, and
          # nothing else. Telling the model to shell out for hex math is useless if every
          # call stops for a confirmation — it learns to guess instead, which is the
          # failure this is meant to fix.
          #
          # `permission.bash` takes a pattern -> action map (most specific pattern wins), so
          # this stays a narrow allowance rather than blanket bash access. python3 is in
          # environment.systemPackages via packages-desktop.nix, and OpenCode's bash tool
          # inherits the user's PATH, so it resolves.
          #
          # Kept deliberately in step with the one command form in re-instructions.md: if
          # you widen the prompt's advice, widen this too, or the model gets prompted and
          # starts improvising again.
          permission.bash = {
            "python3 -c *" = "allow";
            "*" = "ask";
          };
        };
      };
    };
  }) ];
}
