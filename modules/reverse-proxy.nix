# nginx + one wildcard cert for every internal service name.
{ config, lib, ... }:
let
  peers = import ./family/peers.nix;
  domain = "luckyobserver.com";
  cfg = config.fleet.vhosts;
in
{
  options.fleet.vhosts = lib.mkOption {
    default = { };
    description = ''
      Internal service vhosts, keyed by subdomain. `port = null` only attaches the wildcard
      cert to a vhost some other module already defines (nextcloud generates its own).
    '';
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        port = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
        };
        maxBody = lib.mkOption {
          type = lib.types.str;
          default = "1G";
        };
        readTimeout = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        allowedCIDRs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Optional client networks allowed to use this vhost.";
        };
      };
    });
  };

  config = {
    security.acme = {
      acceptTerms = true;
      defaults.email = "se@nheath.com";
    };

    # DNS-01 validates with a TXT record Cloudflare creates and removes, so this works for
    # hosts with no public A record and no inbound 80/443. Secret is an env file holding
    # CF_DNS_API_TOKEN, scoped to Zone:DNS:Edit.
    sops.secrets.acme-dns-credentials = { };
    security.acme.certs.${domain} = {
      domain = "*.${domain}";
      dnsProvider = "cloudflare";
      environmentFile = config.sops.secrets.acme-dns-credentials.path;
      group = "nginx";
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;

      virtualHosts = lib.mapAttrs' (sub: v: lib.nameValuePair "${sub}.${domain}" ({
        useACMEHost = domain;
        forceSSL = true;
      } // lib.optionalAttrs (v.port != null) {
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString v.port}";
          proxyWebsockets = true;
          extraConfig = ''
            client_max_body_size ${v.maxBody};
          '' + lib.optionalString (v.allowedCIDRs != [ ]) ''
            ${lib.concatMapStringsSep "\n" (cidr: "allow ${cidr};") v.allowedCIDRs}
            deny all;
          '' + lib.optionalString (v.readTimeout != null) ''
            proxy_read_timeout ${v.readTimeout};
          '';
        };
      })) cfg;
    };

    # The clients resolve these names from peers.serviceNames (networking.hosts on the
    # NixOS hosts, the router for phones), so a vhost that is not in that list is
    # unreachable by name and nothing else would say so.
    assertions = lib.mapAttrsToList (sub: _: {
      assertion = lib.elem "${sub}.${domain}" peers.serviceNames;
      message = ''
        fleet.vhosts."${sub}" has no matching entry in modules/family/peers.nix
        serviceNames, so clients cannot resolve ${sub}.${domain}.
      '';
    }) cfg;
  };
}
