{ pkgs }:

# Credential-loading entrypoint for the read-only Porkbun MCP server.
pkgs.writeShellApplication {
  name = "porkbun-domain-search-mcp";

  text = ''
    api_key_file=/run/secrets/porkbun-api-key
    secret_key_file=/run/secrets/porkbun-secret-api-key
    ca_bundle=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

    # Codex intentionally gives stdio MCP children a minimal environment. In the ccodex
    # image that strips the only CA-store hint, so Node reports every HTTPS request as the
    # unhelpful `fetch failed`. Make TLS independent of the launching client's policy.
    export SSL_CERT_FILE="''${SSL_CERT_FILE:-$ca_bundle}"
    export NODE_EXTRA_CA_CERTS="''${NODE_EXTRA_CA_CERTS:-$ca_bundle}"

    if [[ -z "''${PORKBUN_API_KEY:-}" ]]; then
      [[ -r "$api_key_file" ]] || {
        printf 'porkbun-domain-search-mcp: cannot read %s\n' "$api_key_file" >&2
        exit 1
      }
      PORKBUN_API_KEY="$(<"$api_key_file")"
    fi

    if [[ -z "''${PORKBUN_SECRET_API_KEY:-}" ]]; then
      [[ -r "$secret_key_file" ]] || {
        printf 'porkbun-domain-search-mcp: cannot read %s\n' "$secret_key_file" >&2
        exit 1
      }
      PORKBUN_SECRET_API_KEY="$(<"$secret_key_file")"
    fi

    [[ "$PORKBUN_API_KEY" == pk1_* ]] || {
      printf '%s\n' 'porkbun-domain-search-mcp: invalid API key format' >&2
      exit 1
    }
    [[ "$PORKBUN_SECRET_API_KEY" == sk1_* ]] || {
      printf '%s\n' 'porkbun-domain-search-mcp: invalid secret API key format' >&2
      exit 1
    }

    export PORKBUN_API_KEY PORKBUN_SECRET_API_KEY
    exec ${pkgs.porkbun-mcp-domain-search}/bin/porkbun-mcp
  '';
}
