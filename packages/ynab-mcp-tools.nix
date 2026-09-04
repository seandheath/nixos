{ pkgs }:

# Pinned Python package for the YNAB MCP server.
pkgs.python3Packages.buildPythonApplication rec {
  pname = "ynab-mcp-tools";
  version = "0.1.0-unstable-2026-07-16";
  pyproject = true;

  src = pkgs.fetchFromGitHub {
    owner = "rgarcia";
    repo = "ynab-mcp-server";
    rev = "cd78abc89e941d7e2d5b28029886dfe3e3c215e2";
    hash = "sha256-3BhgMMKKrmXhwityD9Qxy0YXNOuu5BgexrAXHaQgQas=";
  };

  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = with pkgs.python3Packages; [
    fastmcp
    httpx
    pyyaml
  ];

  dontUsePythonRemoveTestsDir = true;
  checkPhase = ''
    runHook preCheck
    python tests/smoke_test.py
    runHook postCheck
  '';

  meta = {
    description = "MCP server exposing the YNAB API";
    homepage = "https://github.com/rgarcia/ynab-mcp-server";
    license = pkgs.lib.licenses.mit;
    mainProgram = "ynab-mcp-tools";
  };
}
