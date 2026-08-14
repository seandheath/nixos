{ pkgs, ... }:
# Local LLM inference for paperless classification. Loopback only, no vhost, no firewall
# port -- this is an internal dependency, not a service. Models live in /var/lib/ollama on
# root and are deliberately not in backupPaths: a model blob is re-downloadable.
{
  # The P4200 is Pascal (6.1), which is outside nixpkgs' default gencode set, so stock
  # ollama-cuda detects the card and falls back to CPU with total_vram="0 B". Still
  # supported by CUDA 12.8, just not requested by default. Forces a from-source rebuild of
  # the CUDA ggml backend; ollama is hydrogen's only CUDA consumer.
  nixpkgs.config.cudaCapabilities = [ "6.1" ];

  services.ollama = {
    enable = true;

    # NOTE: `services.ollama.acceleration = "cuda"` was REMOVED upstream; the module now
    # wants an explicitly accelerated package. Verified against this flake's locked
    # nixpkgs (nixos-25.11, d407951), nixos/modules/services/misc/ollama.nix:35-39:
    #   mkRemovedOptionModule [...] "acceleration"
    #     "Set `services.ollama.package` to one of `pkgs.ollama[,-vulkan,-rocm,-cuda,-cpu]`"
    package = pkgs.ollama-cuda;

    host = "127.0.0.1";
    port = 11434;

    # Pulled declaratively at activation by the ollama-model-loader unit.
    #
    # qwen2.5:7b at Q4_K_M is ~4.7G, which is the realistic ceiling for the P4200's 8G.
    # Pascal (SM 6.1) has no Flash Attention support, and ollama only quantizes the KV
    # cache when FA is on -- so the cache stays f16 and uses more VRAM than a naive
    # estimate suggests. Leave headroom; do not assume a 12-14B model will fit.
    #
    # Avoid llama3.2 (3B) and phi4 here: both are widely reported to ignore prompt
    # instructions and emit prose where strict JSON was requested, which is exactly the
    # failure mode that breaks metadata extraction. llama3.1:8b is the fallback.
    loadModels = [ "qwen2.5:7b" ];
  };
}
