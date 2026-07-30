{ pkgs, ... }:

# qwen-code wired to the remote vLLM and to Ghidra's ReVa MCP server: a second RE
# client alongside modules/opencode.nix, aimed at the same endpoint and the same
# ReVa server so the two agent loops can be compared on one binary.
#
# modules/opencode.nix carries the shared background and is worth reading first:
# why vLLM is remote and never a NixOS service, why ReVa is loopback-only, and where
# the 262144/32768 numbers come from. Only the qwen-code-specific parts are below.
#
# Unlike OpenCode — which gets a dedicated `re` agent and stays a general coding tool
# otherwise — this install is RE-only: ~/.qwen carries the ReVa MCP server and the RE
# instructions as the global context file, so every `qwen` session is an RE session.
let
  qwen-code = import ../packages/qwen-code.nix { inherit pkgs; };
in
{
  environment.systemPackages = [ qwen-code ];

  # Operating constraints as the global context file. qwen-code appends
  # $QWEN_HOME/QWEN.md to its own core system prompt (as `userMemory`) rather than
  # replacing it — the alternative, QWEN_SYSTEM_MD, substitutes the whole base prompt
  # and would throw away qwen-code's own tool-usage and safety scaffolding.
  #
  # Prose is ported from opencode's re-instructions.md, which already describes this
  # exact ReVa 7.3.0 surface. Keep the two in step: a finding about ReVa's tools
  # applies to both clients.
  #
  # force = true because qwen-code writes to this path itself (`/memory add` appends
  # here), so home-manager must be allowed to overwrite a file it did not create.
  home-manager.users.sheath.home.file.".qwen/QWEN.md" = {
    force = true;
    text = ''
      # Reverse engineering with ReVa

      You are driving Ghidra through the ReVa MCP server. ReVa acts on whichever program
      Ghidra currently has open — you cannot switch programs, and you are not browsing a
      filesystem. This install exists for reverse engineering only; there is no source
      tree to build or test here, so the usual "run the tests" reflex does not apply.

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
      mentally or by "reasoning through" them. Shell out with run_shell_command:

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
  };

  # ~/.qwen/settings.json — deliberately secret-free, referencing the endpoint through
  # $VAR placeholders that qwen-code resolves at load (resolveEnvVarsInObject) from the
  # sops-rendered ~/.qwen/.env below.
  #
  # Why the secrets are NOT inlined here as a sops template, unlike opencode.json and
  # pi-models.json: qwen-code rewrites its own settings.json on startup (it migrates the
  # schema and stamps a "$version" field). Verified against 0.21.1 — that write replaces
  # the sops symlink with a plain **0644** regular file in $HOME. Templating the API key
  # into this file would therefore copy it straight out of the 0400 tmpfs-backed sops
  # store into a world-readable file on every first run. Splitting the secrets into .env
  # avoids that entirely: the rewrite was confirmed to preserve the placeholders
  # unresolved, so the rewritten file still contains no secret.
  #
  # force = true for the same reason — qwen-code owns this path between rebuilds, and
  # activation restores the canonical version.
  home-manager.users.sheath.home.file.".qwen/settings.json" = {
    force = true;
    text = builtins.toJSON {
      # Custom provider. The shape here is the *migrated* one and is not what upstream's
      # published docs show: modelProviders.<id> is a bare array of model entries (the
      # documented { protocol, models } wrapper is silently dropped), and the SDK protocol
      # comes from a separate top-level providerProtocol map. Without that map the models
      # are ignored with "not a built-in protocol". Confirmed by round-tripping the file
      # through qwen-code 0.21.1.
      modelProviders.vllm = [{
        id = "$OPENWEBUI_MODEL";
        # Open WebUI's OpenAI-compatible root, which proxies to the vLLM host. Provider id
        # stays `vllm` since that is what actually serves the tokens.
        baseUrl = "$OPENWEBUI_URL";
        # Names the env var holding the key rather than the key itself — the one field
        # that is an env var *reference* by design instead of $VAR interpolation.
        envKey = "OPENWEBUI_API_KEY";
        # generationConfig belongs on the model entry, not under top-level `model`.
        # Putting it there is accepted but ignored, with a warning naming this location.
        generationConfig = {
          # The endpoint's advertised max_model_len. qwen-code compacts against this, so
          # setting it above the server's real limit invites context overflow mid-task.
          contextWindowSize = 262144;
          samplingParams = {
            # Client-side reservation out of the same 262144, not a separate server cap.
            # 32768 because the served model reasons before answering; see the longer
            # note in modules/opencode.nix. Keep this file, modules/opencode.nix and
            # home/sheath.nix in step — all three describe the same endpoint.
            max_tokens = 32768;
          };
        };
      }];
      providerProtocol.vllm = "openai";

      security.auth.selectedType = "openai";
      model.name = "$OPENWEBUI_MODEL";

      # Default, stated explicitly: this is the QWEN.md written above.
      context.fileName = "QWEN.md";

      # ReVa. Note both the key and the path: `httpUrl` selects
      # StreamableHTTPClientTransport (plain `url` would select SSE, which ReVa does not
      # serve), and ReVa 7.3.0 serves at /mcp/message on 8080, not the /mcp the upstream
      # spec shows. The endpoint only responds while Ghidra has a program open.
      mcpServers.reva.httpUrl = "http://localhost:8080/mcp/message";

      # Pre-approve exactly the arithmetic escape hatch QWEN.md tells the model to use,
      # and nothing else — instructing it to shell out is useless if every call stops for
      # a confirmation, because it learns to guess instead. Scoping was verified: a
      # `touch` still prompts under this rule.
      #
      # The tool must be spelled `run_shell_command`. qwen-code's schema documentation
      # advertises "Bash(git *)" and its alias table maps Bash -> run_shell_command, but
      # rules written as Bash(...) do not actually match in 0.21.1's approval path —
      # tested, and both the bare and parenthesised Bash forms still prompted.
      # `ShellTool` also works; `run_shell_command` is the canonical wire name.
      permissions.allow = [ "run_shell_command(python3 -c *)" ];
    };
  };

  # The endpoint's identifying details (base URL, served model id, token) are all secrets,
  # so they are rendered from sops into the one file qwen-code reads but never writes.
  # $QWEN_HOME/.env is the first candidate its findEnvFiles() checks.
  #
  # Imported as a sub-module rather than assigned by attr path so that `config` here is
  # home-manager's, not the NixOS one: `config.sops.placeholder` only exists inside the
  # home-manager sops module's own evaluation. Same trick as modules/opencode.nix.
  home-manager.users.sheath.imports = [ ({ config, ... }: {
    # Re-declared here rather than leaning on home/sheath.nix's pi block, so this feature
    # stands alone if pi is ever dropped. Identical sops.secrets submodule definitions
    # merge cleanly. `defaultSopsFile` and `age.keyFile` are NOT re-declared — those are
    # set once in home/sheath.nix for every non-hydrogen host.
    sops.secrets."openwebui-url" = { };
    sops.secrets."openwebui-model" = { };
    sops.secrets."openwebui-api-key" = { };

    sops.templates."qwen-env" = {
      path = "${config.home.homeDirectory}/.qwen/.env";
      # Values are left unquoted: dotenv takes the rest of the line verbatim, and all
      # three are single-token (a URL, a model id, an sk- token).
      content = ''
        OPENWEBUI_URL=${config.sops.placeholder."openwebui-url"}
        OPENWEBUI_MODEL=${config.sops.placeholder."openwebui-model"}
        OPENWEBUI_API_KEY=${config.sops.placeholder."openwebui-api-key"}
      '';
    };
  }) ];
}
