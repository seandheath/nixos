{ pkgs, ... }:
let
  vllm = import ./vllm-endpoint.nix;
in

# OpenCode: the agent loop of the RE stack, pointed at the remote vLLM
# (modules/vllm-endpoint.nix) and Ghidra's ReVa MCP server (packages/ghidra-reva.nix).
# Imported from workstation.nix, which is the host gate -- hydrogen never evaluates this.
{
  environment.systemPackages = [ pkgs.opencode pkgs.reference-download ];
  environment.variables.OPENCODE_ENABLE_EXA = "1";

  # prompts/re-agent.md is the canonical copy, shared with qwen-code.nix; keep it
  # client-neutral, since the two name the shell tool differently. NOT called AGENTS.md:
  # OpenCode auto-loads that into every session, where this prose is noise.
  home-manager.users.sheath.xdg.configFile."opencode/re-instructions.md" = {
    source = ../prompts/re-agent.md;
    force = true;
  };

  # Available to the host OpenCode. The container launcher mounts this same resolved tree,
  # so both clients use one canonical copy and load it only when the workflow is relevant.
  home-manager.users.sheath.xdg.configFile."opencode/skills/datasheet-reference" = {
    source = ../skills/datasheet-reference;
    recursive = true;
    force = true;
  };

  # One sops template rather than a plain configFile: all three identifying details of the
  # endpoint are secrets, and nothing model-identifying may land in the public flake or the
  # store. Imported as a sub-module so `config` here is home-manager's -- sops.placeholder
  # exists only inside its own evaluation.
  home-manager.users.sheath.imports = [ ({ config, lib, ... }: {
    # Re-declared rather than leaning on home/sheath.nix's pi block, so this stands alone if
    # pi is dropped; identical sops.secrets definitions merge.
    sops.secrets = lib.genAttrs vllm.secretNames (_: { });

    sops.templates."opencode.json" = {
      path = "${config.home.homeDirectory}/.config/opencode/opencode.json";
      content = builtins.toJSON {
        "$schema" = "https://opencode.ai/config.json";

        # The served model is not in models.dev, so the SDK and the capabilities have to be
        # spelled out. @ai-sdk/openai-compatible is already in the nixpkgs opencode closure,
        # so this resolves offline. The URL is Open WebUI's OpenAI-compatible root, which
        # proxies to vLLM; tool calling through that proxy is verified working.
        provider.vllm = {
          npm = "@ai-sdk/openai-compatible";
          name = "vLLM (via Open WebUI)";
          options = {
            baseURL = config.sops.placeholder."openwebui-url";
            apiKey = config.sops.placeholder."openwebui-api-key";
          };
          # The model id is a secret, so it is a dynamic attribute name -- Nix takes the
          # opaque placeholder string and sops substitutes every occurrence at activation.
          models.${config.sops.placeholder."openwebui-model"} = {
            # Without a models.dev entry OpenCode does not know the model can call tools,
            # and would never offer it the ReVa tools.
            tool_call = true;
            limit = {
              # OpenCode compacts against this, so setting it above the server's real limit
              # overflows context mid-task.
              context = vllm.contextWindow;
              output = vllm.maxOutput;
            };
          };
        };

        model = "vllm/${config.sops.placeholder."openwebui-model"}";
        # Only one model is served; split this out if a smaller one is ever added.
        small_model = "vllm/${config.sops.placeholder."openwebui-model"}";

        # ReVa 7.3.0 serves at /mcp/message, not /mcp, and only while Ghidra has a program
        # open -- which is also why loopback is correct.
        mcp.reva = {
          type = "remote";
          url = "http://localhost:8080/mcp/message";
          enabled = true;
        };

        # `opencode --agent re`, or Tab. primary = selectable as a top-level agent.
        agent.re = {
          description = "Reverse engineering against the program currently open in Ghidra/ReVa";
          mode = "primary";
          # {file:…} is interpolated at config load, which keeps the prose greppable.
          prompt = "{file:${config.home.homeDirectory}/.config/opencode/re-instructions.md}";
          # Pre-approve exactly the arithmetic escape hatch prompts/re-agent.md tells it to
          # use, and nothing else: telling the model to shell out for hex math is useless if
          # every call stops for confirmation -- it learns to guess instead. Most specific
          # pattern wins, so this is a narrow allowance, not blanket bash. Keep in step with
          # the command forms in that prompt.
          permission.bash = {
            "python3 -c *" = "allow";
            "reference-download *" = "allow";
            "*" = "ask";
          };
          permission.skill."datasheet-reference" = "allow";
          permission.webfetch = "allow";
          permission.websearch = "allow";
        };
      };
    };
  }) ];
}
