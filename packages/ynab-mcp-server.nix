{ pkgs }:

# Credential-loading entrypoint for the YNAB MCP server.
pkgs.writeShellApplication {
  name = "ynab-mcp-server";
  text = ''
    token_file=/run/secrets/ynab-api-token
    if [[ ! -r "$token_file" ]]; then
      printf 'ynab-mcp-server: cannot read %s\n' "$token_file" >&2
      exit 1
    fi

    YNAB_API_TOKEN="$(< "$token_file")"
    if [[ -z "$YNAB_API_TOKEN" ]]; then
      printf '%s\n' 'ynab-mcp-server: YNAB API token is empty' >&2
      exit 1
    fi
    export YNAB_API_TOKEN

    exec ${pkgs.ynab-mcp-tools}/bin/ynab-mcp-tools
  '';
}
