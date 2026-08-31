{ config, lib, pkgs, ... }:

# Facebook Marketplace monitor in the upstream container. Search criteria stay mutable in
# the web UI; Nix owns the runtime, secret injection, initial Qwen backend, and persistence.
let
  vllm = import ./vllm-endpoint.nix;
  stateDir = "/var/lib/ai-marketplace-monitor";

  # Keep the Web UI override matched to the exact source revision labeled on the pinned
  # container image. Upstream's restart endpoint touches config.toml, but its frontend
  # otherwise retains the old optimistic-lock mtime and reports a false edit conflict.
  upstreamSrc = pkgs.fetchFromGitHub {
    owner = "BoPeng";
    repo = "ai-marketplace-monitor";
    rev = "4d18385dc6337937dae4abcb2069033b16c4a95b";
    hash = "sha256-YcmHqNlowpaEPfajzF0RteW+jXwXuSjlsSSd74z6JM4=";
  };
  patchedWebUI = pkgs.stdenvNoCC.mkDerivation {
    pname = "ai-marketplace-monitor-webui";
    version = "4d18385";
    src = upstreamSrc;
    patches = [ ./ai-marketplace-monitor-webui-mtime.patch ];
    installPhase = ''
      install -Dm0444 src/ai_marketplace_monitor/webui/static/app.js $out/app.js
    '';
  };

  # The upstream CLI configures the root logger at DEBUG. Two dependency loggers then
  # serialize every inotify event and the complete scheduled job, whose repr includes the
  # Facebook password. sitecustomize runs before the application configures logging, and
  # these explicit child levels remain effective afterward.
  pythonLogPolicy = pkgs.writeTextDir "sitecustomize.py" ''
    import logging

    for logger_name in ("schedule", "watchdog"):
        logging.getLogger(logger_name).setLevel(logging.WARNING)
  '';

  # tmpfiles copies this only when config.toml does not exist. Once seeded, the web UI owns
  # the live file in stateDir, so a rebuild cannot erase searches added interactively.
  initialConfig = pkgs.writeText "ai-marketplace-monitor-config.toml" ''
    # Seeded by NixOS on first deployment. Manage this file through the web UI afterward.

    [marketplace.facebook]
    # Credentials intentionally come from FACEBOOK_USERNAME/FACEBOOK_PASSWORD. The
    # upstream Web UI auth parser uses that fallback only when these fields are absent.
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
      image = "ghcr.io/bopeng/ai-marketplace-monitor@sha256:ab612a781b59992e6ceca82c9aab19ba76cbc9cfb05d2e50aae7eb5651403d3a";
      pull = "missing";
      autoStart = true;

      # nginx is the only network entry point; it terminates TLS and restricts the vhost
      # to wgadm. Publishing specifically on loopback also avoids bypassing that ACL.
      ports = [ "127.0.0.1:8467:8467" ];
      volumes = [
        "${stateDir}:/root/.ai-marketplace-monitor"
        "${patchedWebUI}/app.js:/usr/local/lib/python3.12/site-packages/ai_marketplace_monitor/webui/static/app.js:ro"
        "${pythonLogPolicy}:/opt/aimm-python-policy:ro"
      ];
      environment.PYTHONPATH = "/opt/aimm-python-policy";
      environmentFiles = [ config.sops.templates."ai-marketplace-monitor-env".path ];

      capabilities.ALL = false;
      extraOptions = [ "--security-opt=no-new-privileges" "--umask=0077" ];
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
    # Migrate the first deployed seed without touching credentials entered directly by a
    # user. Upstream's Web UI treated these exact placeholders literally instead of
    # expanding them, which made the real Facebook credentials fail Web UI authentication.
    preStart = ''
      if ${pkgs.gnugrep}/bin/grep -Eq \
        '^[[:space:]]*(username|password) = "\$\{FACEBOOK_(USERNAME|PASSWORD)\}"[[:space:]]*$' \
        ${stateDir}/config.toml; then
        ${pkgs.gnused}/bin/sed -i \
          -e '/^[[:space:]]*username = "''${FACEBOOK_USERNAME}"[[:space:]]*$/d' \
          -e '/^[[:space:]]*password = "''${FACEBOOK_PASSWORD}"[[:space:]]*$/d' \
          ${stateDir}/config.toml
      fi

      # Earlier upstream DEBUG logs serialized scheduled-job arguments, including the
      # Facebook credentials. Replace those exact secret values in retained rotated logs
      # before the hardened process starts; the secret values never enter argv or the store.
      for log_file in ${stateDir}/ai-marketplace-monitor.log*; do
        if test -e "$log_file"; then
          ${pkgs.perl}/bin/perl -0pi -e '
            BEGIN {
              local $/;
              open my $uf, "<", "${config.sops.secrets."aimm-facebook-username".path}" or die $!;
              $username = <$uf>;
              open my $pf, "<", "${config.sops.secrets."aimm-facebook-password".path}" or die $!;
              $password = <$pf>;
            }
            s/\Q$username\E/<redacted-facebook-username>/g if length $username;
            s/\Q$password\E/<redacted-facebook-password>/g if length $password;
          ' "$log_file"
        fi
      done
    '';
  };
}
