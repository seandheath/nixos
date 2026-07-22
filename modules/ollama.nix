{ pkgs, ... }:
# Local LLM inference server, used by paperless document classification.
#
# Bound to loopback only and deliberately given no nginx vhost: this is an internal
# dependency of other services, not something reachable at *.luckyobserver.com. Nothing
# is added to networking.firewall.allowedTCPPorts either.
#
# Models are pulled into the default /var/lib/ollama (state dir), which lives on root --
# 395G free there, so there is no reason to put them on /data and inherit the
# RequiresMountsFor = "/data" guard that modules/immich.nix and modules/backup.nix need.
# Backed up implicitly? No -- deliberately NOT added to modules/backup.nix backupPaths,
# since a model blob is re-downloadable and would only bloat the borg repo.
{
  # The P4200 is Pascal (compute capability 6.1). nixpkgs' CUDA capability DB marks 6.1
  # with dontDefaultAfterCudaMajorMinorVersion = "12.3", and the toolkit here is 12.8, so
  # Pascal is NOT in the default gencode set -- pkgs.ollama-cuda ships kernels for sm_75+
  # (Turing onward) only. At runtime ollama detects the card but logs "filtering device
  # which didn't fully initialize" and falls back to CPU, because ggml-cuda has no Pascal
  # kernels. 6.1 is still *supported* by CUDA 12.8 (NVIDIA drops Pascal only in CUDA 13),
  # it just has to be requested explicitly. This forces a from-source rebuild of the CUDA
  # ggml backend; ollama is the only CUDA consumer on hydrogen so the blast radius is just
  # that package. Verified empirically 2026-07-21: without this, total_vram="0 B".
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
