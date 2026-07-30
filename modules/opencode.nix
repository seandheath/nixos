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
  # The prose is shared: prompts/re-agent.md is the single canonical copy, deployed
  # verbatim here and to ~/.qwen/QWEN.md by modules/qwen-code.nix. It used to be inlined
  # in both modules with a comment asking future-us to keep them in step, which lasted
  # exactly one session before they drifted. Edit the canonical file, never this path.
  # Keep that file client-neutral — in particular it must not name a shell tool, since
  # OpenCode calls it `bash` and qwen-code calls it `run_shell_command`.
  #
  # Deliberately NOT named AGENTS.md: OpenCode auto-loads a global
  # ~/.config/opencode/AGENTS.md into *every* session, and "never bulk-decompile" is
  # noise in an ordinary coding session (and would then be included twice, once
  # globally and once via agent.re.prompt). A non-magic filename referenced explicitly
  # from agent.re.prompt scopes it to RE work only. The deployed path is unchanged, so
  # agent.re.prompt's {file:…} reference below still resolves.
  home-manager.users.sheath.xdg.configFile."opencode/re-instructions.md" = {
    source = ../prompts/re-agent.md;
    force = true;
  };

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
          # Kept deliberately in step with the command forms in prompts/re-agent.md: if you
          # widen the prompt's advice, widen this too, or the model gets prompted and
          # starts improvising again.
          #
          # The pattern covers multi-statement forms too — `python3 -c 'import struct; …'`
          # runs unprompted, because a semicolon inside the quoted -c argument does not
          # split the command for matching. That matters: the bitwise/endianness/float
          # guidance in prompts/re-agent.md needs `import struct`. Verified against a
          # control (a bare `touch` under `opencode run` does block), so this is the rule
          # matching and not non-interactive auto-approval.
          permission.bash = {
            "python3 -c *" = "allow";
            "*" = "ask";
          };
        };
      };
    };
  }) ];
}
