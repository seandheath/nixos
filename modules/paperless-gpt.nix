{ config, ... }:
# paperless-gpt (icereed/paperless-gpt) -- LLM auto-classification companion for paperless.
#
# Watches paperless for documents carrying the `paperless-gpt-auto` tag and writes back an
# LLM-generated title, tags, correspondent and document type. Talks only to two loopback
# services on hydrogen: paperless (127.0.0.1:28981) and ollama (127.0.0.1:11434). Its own
# web UI is bound to 127.0.0.1:8080 and is NOT exposed -- no nginx vhost, no firewall port.
#
# Not in nixpkgs (no package, no module), so it runs as a pinned OCI container. Hydrogen had
# no container runtime before this; podman is enabled here rather than by importing the
# desktop-oriented modules/virtualisation.nix (which sulfur/osmium use and which would drag
# in virt-manager etc.).
#
# The paperless API token lives in sops (`paperless-gpt-token`, an env file containing
# PAPERLESS_API_TOKEN=...) and is injected via environmentFiles. Generate/rotate it in the
# paperless UI: Settings -> API tokens; it cannot be provisioned declaratively.
{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  sops.secrets.paperless-gpt-token = { };

  # State dirs for the container (PUID/PGID default to 10001 inside the image, so the bind
  # mounts must be writable by that uid under rootful podman, where there is no userns remap).
  # /app/config persists the UI settings; /app/prompts holds custom prompt templates.
  systemd.tmpfiles.rules = [
    "d /var/lib/paperless-gpt        0750 10001 10001 -"
    "d /var/lib/paperless-gpt/config  0750 10001 10001 -"
    "d /var/lib/paperless-gpt/prompts 0750 10001 10001 -"
  ];

  virtualisation.oci-containers.containers.paperless-gpt = {
    image = "ghcr.io/icereed/paperless-gpt:v0.27.0";

    # Host networking so the container reaches paperless and ollama on the host's loopback
    # without a bridge or host.containers.internal gymnastics. The app's own listener is
    # still pinned to 127.0.0.1 below, and 8080 is not in the host firewall allowlist.
    extraOptions = [ "--network=host" ];

    environment = {
      PAPERLESS_BASE_URL = "http://127.0.0.1:28981";

      LLM_PROVIDER = "ollama";
      LLM_MODEL = "qwen2.5:7b";
      OLLAMA_HOST = "http://127.0.0.1:11434";
      # Matches services.ollama default context; sent to ollama as num_ctx.
      OLLAMA_CONTEXT_LENGTH = "8192";

      LISTEN_INTERFACE = "127.0.0.1:8080";

      # Start conservative: the model may only assign tags that already exist in paperless,
      # so a hallucinated tag can't pollute the taxonomy. Loosen once output is trusted.
      CREATE_NEW_TAGS = "false";

      LLM_LANGUAGE = "English";
      LOG_LEVEL = "info";
    };

    # Contains PAPERLESS_API_TOKEN=... ; read as root at container start.
    environmentFiles = [ config.sops.secrets.paperless-gpt-token.path ];

    volumes = [
      "/var/lib/paperless-gpt/config:/app/config"
      "/var/lib/paperless-gpt/prompts:/app/prompts"
    ];
  };

  # Soft ordering: paperless-gpt polls and retries, but start it after its dependencies so a
  # boot doesn't log a burst of connection errors before paperless/ollama are listening.
  systemd.services.podman-paperless-gpt = {
    after = [ "ollama.service" "paperless-web.service" ];
    wants = [ "ollama.service" "paperless-web.service" ];
  };
}
