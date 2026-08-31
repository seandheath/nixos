{ config, lib, pkgs, ... }:

# Facebook Marketplace monitor in the upstream container. Search criteria stay mutable in
# the web UI; Nix owns the runtime, secret injection, initial Qwen backend, and persistence.
let
  vllm = import ./vllm-endpoint.nix;
  stateDir = "/var/lib/ai-marketplace-monitor";

  # tmpfiles copies this only when config.toml does not exist. Once seeded, the web UI owns
  # the live file in stateDir, so a rebuild cannot erase searches added interactively.
  initialConfig = pkgs.writeText "ai-marketplace-monitor-config.toml" ''
    # Seeded by NixOS on first deployment. Manage this file through the web UI afterward.

    [marketplace.facebook]
    username = "''${FACEBOOK_USERNAME}"
    password = "''${FACEBOOK_PASSWORD}"
    search_city = "houston"

    [ai.qwen]
    provider = "openai"
    base_url = "''${OPENWEBUI_URL}"
    api_key = "''${OPENWEBUI_API_KEY}"
    model = "''${OPENWEBUI_MODEL}"
    timeout = 120

    # Keeps the initial config valid without running an accidental search. Replace this in
    # the web UI, set the real city, then enable the item when it is ready.
    [item.configure_me]
    enabled = false
    search_phrases = "configure me"
    ai = "qwen"

    [user.me]
  '';
in
{
  virtualisation.podman.enable = true;
  virtualisation.oci-containers = {
    backend = "podman";
    containers.ai-marketplace-monitor = {
      image = "ghcr.io/bopeng/ai-marketplace-monitor:latest";
      pull = "newer";
      autoStart = true;

      # nginx is the only network entry point; it terminates TLS and restricts the vhost
      # to wgadm. Publishing specifically on loopback also avoids bypassing that ACL.
      ports = [ "127.0.0.1:8467:8467" ];
      volumes = [ "${stateDir}:/root/.ai-marketplace-monitor" ];
      environmentFiles = [ config.sops.templates."ai-marketplace-monitor-env".path ];

      capabilities.ALL = false;
      extraOptions = [ "--security-opt=no-new-privileges" ];
    };
  };

  sops.secrets = lib.genAttrs (
    vllm.secretNames ++ [ "aimm-facebook-username" "aimm-facebook-password" ]
  ) (_: { });

  # The container is rootful and the file remains in sops' tmpfs; Podman reads it at
  # startup and passes values as environment variables without copying them to the store.
  sops.templates."ai-marketplace-monitor-env" = {
    owner = "root";
    mode = "0400";
    content = ''
      FACEBOOK_USERNAME=${config.sops.placeholder."aimm-facebook-username"}
      FACEBOOK_PASSWORD=${config.sops.placeholder."aimm-facebook-password"}
      OPENWEBUI_URL=${config.sops.placeholder."openwebui-url"}
      OPENWEBUI_MODEL=${config.sops.placeholder."openwebui-model"}
      OPENWEBUI_API_KEY=${config.sops.placeholder."openwebui-api-key"}
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    "C ${stateDir}/config.toml 0600 root root - ${initialConfig}"
  ];

  systemd.services.podman-ai-marketplace-monitor = {
    # sops-nix renders secrets in the activation script on this host (rather than via a
    # systemd unit), so they are already present before switched services are restarted.
    after = [ "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = stateDir;
  };
}
