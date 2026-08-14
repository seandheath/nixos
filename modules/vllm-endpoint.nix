# The remote vLLM endpoint, fronted by Open WebUI. Consumed by opencode.nix, qwen-code.nix
# and home/sheath.nix, which each described it separately with a comment asking a human to
# keep the three in step.
#
# vLLM is not a NixOS service anywhere in this flake and should not be proposed as one: the
# only always-on GPU box is hydrogen, whose Quadro P4200 is Pascal (SM 6.1), and vLLM
# requires compute capability >= 7.0.
{
  # Read from the endpoint's GET /models on 2026-07-30.
  contextWindow = 262144;

  # Reserved out of contextWindow, not an independent server limit -- vLLM caps only
  # max_tokens <= max_model_len. This large because the served model reasons before
  # answering.
  maxOutput = 32768;

  # The URL, model id and API key are secrets; see secrets/secrets.yaml.
  secretNames = [ "openwebui-url" "openwebui-model" "openwebui-api-key" ];
}
