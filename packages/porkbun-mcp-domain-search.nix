{ pkgs }:

# Porkbun MCP server restricted at build time to credential checks and domain research.
pkgs.buildNpmPackage rec {
  pname = "porkbun-mcp-domain-search";
  version = "0.17.1";

  src = pkgs.fetchFromGitHub {
    owner = "oborseth";
    repo = "Porkbun-MCP";
    rev = "a7afea403e7ec2c8552b5c192c478b34c29be569";
    hash = "sha256-TFO/Gefr6rGEd9DFJS+cagUl+KXTP5wo4Z09GMbwax4=";
  };

  npmDepsHash = "sha256-9e9V/adq/c5vdgn7nF5Aq2bFMiIuOEmCRqIPHR9HGO8=";

  # A registrar key must never turn a naming assistant into a registration or DNS agent.
  postPatch = ''
    substituteInPlace src/index.ts \
      --replace-fail \
        'for (const tool of tools) {' \
        'for (const tool of tools.filter((candidate) => ["ping", "check_domain", "get_pricing"].includes(candidate.name))) {'
  '';

  meta = {
    description = "Porkbun MCP server restricted to domain availability and pricing";
    homepage = "https://github.com/oborseth/Porkbun-MCP";
    license = pkgs.lib.licenses.mit;
    mainProgram = "porkbun-mcp";
  };
}
