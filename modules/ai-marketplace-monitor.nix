{ config, lib, pkgs, ... }:

# Facebook Marketplace monitor in the upstream container. Search criteria stay mutable in
# the web UI; Nix owns the runtime, secret injection, initial Qwen backend, and persistence.
let
  vllm = import ./vllm-endpoint.nix;
  stateDir = "/var/lib/ai-marketplace-monitor";
  talkRelayPort = 8468;
  talkRelayUser = "ai-marketplace-talk-relay";

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

  # ai-marketplace-monitor already knows how to send ntfy-compatible webhooks. This
  # small adapter keeps that upstream integration and turns each webhook into a signed
  # message from a response-only bot in the private Nextcloud Talk conversation.
  talkRelay = pkgs.writeTextFile {
    name = "ai-marketplace-monitor-talk-relay";
    executable = true;
    text = ''
      #!${pkgs.python3}/bin/python3
      import hashlib
      import hmac
      import ipaddress
      import json
      import os
      import secrets
      import sys
      import urllib.error
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
      from pathlib import Path
      from urllib.parse import urlsplit

      LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "${toString talkRelayPort}"))
      NEXTCLOUD_URL = os.environ["NEXTCLOUD_URL"].rstrip("/")
      BOT_SECRET = Path(os.environ["BOT_SECRET_FILE"]).read_text().strip().encode()
      ROOM_TOKEN = Path(os.environ["ROOM_TOKEN_FILE"]).read_text().strip()
      PODMAN_NETWORK = ipaddress.ip_network("10.88.0.0/16")
      MAX_REQUEST_BYTES = 64 * 1024
      MAX_MESSAGE_CHARS = 24_000

      if len(BOT_SECRET) < 40 or not ROOM_TOKEN:
          raise RuntimeError("invalid Talk bot credentials")

      class Handler(BaseHTTPRequestHandler):
          server_version = "MarketplaceTalkRelay/1"

          def log_message(self, _format, *args):
              # Never log notification bodies or headers: listing descriptions can
              # contain arbitrary content and the request is otherwise self-contained.
              print(f"request from {self.client_address[0]}: {args[1]}", file=sys.stderr)

          def send_empty(self, status):
              self.send_response(status)
              self.send_header("Content-Length", "0")
              self.end_headers()

          def do_GET(self):
              if urlsplit(self.path).path == "/healthz":
                  self.send_empty(200)
              else:
                  self.send_empty(404)

          def do_POST(self):
              try:
                  source = ipaddress.ip_address(self.client_address[0])
              except ValueError:
                  self.send_empty(403)
                  return
              if not (source.is_loopback or source in PODMAN_NETWORK):
                  self.send_empty(403)
                  return
              if urlsplit(self.path).path != "/marketplace":
                  self.send_empty(404)
                  return

              try:
                  length = int(self.headers.get("Content-Length", ""))
              except ValueError:
                  self.send_empty(400)
                  return
              if length < 1 or length > MAX_REQUEST_BYTES:
                  self.send_empty(413)
                  return

              body = self.rfile.read(length).decode("utf-8", errors="replace").strip()
              title = self.headers.get("Title", "Marketplace alert").strip()
              title = title[:300] or "Marketplace alert"
              message = f"**{title}**\n\n{body}"[:MAX_MESSAGE_CHARS]

              random_seed = secrets.token_hex(32)
              signature = hmac.new(
                  BOT_SECRET,
                  (random_seed + message).encode(),
                  hashlib.sha256,
              ).hexdigest()
              payload = json.dumps({"message": message}).encode()
              request = urllib.request.Request(
                  f"{NEXTCLOUD_URL}/ocs/v2.php/apps/spreed/api/v1/bot/{ROOM_TOKEN}/message",
                  data=payload,
                  method="POST",
                  headers={
                      "Accept": "application/json",
                      "Content-Type": "application/json",
                      "OCS-APIRequest": "true",
                      "X-Nextcloud-Talk-Bot-Random": random_seed,
                      "X-Nextcloud-Talk-Bot-Signature": signature,
                  },
              )
              try:
                  with urllib.request.urlopen(request, timeout=20) as response:
                      if response.status != 201:
                          raise RuntimeError(f"unexpected Talk status {response.status}")
              except urllib.error.HTTPError as error:
                  print(f"Talk API returned HTTP {error.code}", file=sys.stderr)
                  self.send_empty(502)
                  return
              except Exception as error:
                  print(f"Talk API request failed: {type(error).__name__}", file=sys.stderr)
                  self.send_empty(502)
                  return

              self.send_empty(204)

      server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
      server.serve_forever()
    '';
  };

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
    ntfy_server = "http://host.containers.internal:${toString talkRelayPort}"
    ntfy_topic = "marketplace"
    message_format = "markdown"
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

  users.groups.${talkRelayUser} = { };
  users.users.${talkRelayUser} = {
    isSystemUser = true;
    group = talkRelayUser;
  };

  sops.secrets =
    lib.genAttrs (
      vllm.secretNames ++ [ "aimm-facebook-username" "aimm-facebook-password" ]
    ) (_: { })
    // {
      "aimm-nextcloud-talk-bot-secret" = {
        owner = talkRelayUser;
        group = talkRelayUser;
        mode = "0400";
      };
      "aimm-nextcloud-talk-room-token" = {
        owner = talkRelayUser;
        group = talkRelayUser;
        mode = "0400";
      };
    };

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

  # The listener binds on all local addresses so it can start before podman0 exists. The
  # firewall only opens it on podman0, and the handler independently rejects callers
  # outside Podman's default rootful subnet.
  networking.firewall.interfaces."podman0".allowedTCPPorts = [ talkRelayPort ];

  systemd.services.ai-marketplace-monitor-talk-relay = {
    description = "AI Marketplace Monitor to Nextcloud Talk relay";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      User = talkRelayUser;
      Group = talkRelayUser;
      ExecStart = "${talkRelay}";
      Environment = [
        "LISTEN_PORT=${toString talkRelayPort}"
        "NEXTCLOUD_URL=https://nc.luckyobserver.com"
        "BOT_SECRET_FILE=${config.sops.secrets."aimm-nextcloud-talk-bot-secret".path}"
        "ROOM_TOKEN_FILE=${config.sops.secrets."aimm-nextcloud-talk-room-token".path}"
      ];
      Restart = "on-failure";
      RestartSec = "5s";

      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = "";
    };
  };

  systemd.services.podman-ai-marketplace-monitor = {
    # sops-nix renders secrets in the activation script on this host (rather than via a
    # systemd unit), so they are already present before switched services are restarted.
    requires = [ "ai-marketplace-monitor-talk-relay.service" ];
    after = [ "systemd-tmpfiles-setup.service" "ai-marketplace-monitor-talk-relay.service" ];
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

      # The live config is intentionally Web-UI-managed, so add the Talk notifier once
      # for hosts seeded before this integration existed and leave later user edits alone.
      if ! test -e ${stateDir}/.nextcloud-talk-alerts-v1; then
        if ${pkgs.gnugrep}/bin/grep -Fxq '[user.me]' ${stateDir}/config.toml \
          && ! ${pkgs.gnugrep}/bin/grep -Eq '^[[:space:]]*ntfy_server[[:space:]]*=' ${stateDir}/config.toml; then
          ${pkgs.gnused}/bin/sed -i '/^\[user\.me\]$/a\
ntfy_server = "http://host.containers.internal:${toString talkRelayPort}"\
ntfy_topic = "marketplace"\
message_format = "markdown"' ${stateDir}/config.toml
        fi
        touch ${stateDir}/.nextcloud-talk-alerts-v1
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
