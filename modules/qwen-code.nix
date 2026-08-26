{ pkgs, ... }:

# A second RE client alongside modules/opencode.nix, on the same endpoint and the same
# ReVa server so the two agent loops can be compared on one binary. Unlike OpenCode this
# install is RE-only: the instructions are the global context file, so every session is
# an RE session.
let
  vllm = import ./vllm-endpoint.nix;
  settings = {
    # The MIGRATED shape, not what upstream's docs show: modelProviders.<id> is a bare
    # array and the SDK protocol comes from the separate providerProtocol map.
    modelProviders.vllm = [{
      id = "$OPENWEBUI_MODEL";
      baseUrl = "$OPENWEBUI_URL";
      envKey = "OPENWEBUI_API_KEY";
      generationConfig = {
        contextWindowSize = vllm.contextWindow;
        samplingParams.max_tokens = vllm.maxOutput;
      };
    }];
    providerProtocol.vllm = "openai";

    security.auth.selectedType = "openai";
    model.name = "$OPENWEBUI_MODEL";
    context.fileName = "QWEN.md";

    mcpServers = {
      # `httpUrl` selects StreamableHTTPClientTransport; ReVa does not serve SSE.
      reva.httpUrl = "http://localhost:8080/mcp/message";
      porkbun = {
        command = "porkbun-domain-search-mcp";
        includeTools = [ "ping" "check_domain" "get_pricing" ];
        trust = true;
      };
    };

    # The MCP binary exposes only these three read-only calls, so trusting its tools cannot
    # register domains, spend credit, inspect the account, or alter DNS.
    permissions.allow = [ "run_shell_command(python3 -c *)" ];
  };

  # The container launchers are RE-specific and deliberately receive no registrar secret.
  reSettings = settings // {
    mcpServers = builtins.removeAttrs settings.mcpServers [ "porkbun" ];
  };
in
{
  environment.systemPackages = [ pkgs.qwen-code ];

  # QWEN.md is appended to qwen-code's own system prompt as userMemory; the alternative,
  # QWEN_SYSTEM_MD, would replace the base prompt and throw away its tool-usage and safety
  # scaffolding. prompts/re-agent.md is the canonical copy, shared with opencode.nix.
  # force: qwen-code writes here itself (`/memory add`).
  home-manager.users.sheath.home.file.".qwen/QWEN.md" = {
    source = ../prompts/re-agent.md;
    force = true;
  };

  # Deliberately secret-free: qwen-code rewrites this file on startup, replacing the sops
  # symlink with a plain 0644 file in $HOME. Templating the key in here would copy it out
  # of the 0400 tmpfs store into a world-readable file on first run. The $VAR placeholders
  # survive that rewrite unresolved and are read from the sops-rendered .env below.
  home-manager.users.sheath.home.file.".qwen/settings.json" = {
    force = true;
    text = builtins.toJSON settings;
  };

  home-manager.users.sheath.home.file.".qwen/re-settings.json" = {
    text = builtins.toJSON reSettings;
  };

  # Rendered into the one file qwen-code reads but never writes. Sub-module so `config` is
  # home-manager's -- sops.placeholder exists only inside its own evaluation.
  home-manager.users.sheath.imports = [ ({ config, lib, ... }: {
    sops.secrets = lib.genAttrs vllm.secretNames (_: { });

    sops.templates."qwen-env" = {
      path = "${config.home.homeDirectory}/.qwen/.env";
      # Unquoted: dotenv takes the rest of the line verbatim and all three are single-token.
      content = ''
        OPENWEBUI_URL=${config.sops.placeholder."openwebui-url"}
        OPENWEBUI_MODEL=${config.sops.placeholder."openwebui-model"}
        OPENWEBUI_API_KEY=${config.sops.placeholder."openwebui-api-key"}
      '';
    };
  }) ];
}
