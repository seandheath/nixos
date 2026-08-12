{ pkgs }:

# qwen-code, QwenLM's fork of gemini-cli, at the latest upstream stable release.
# Upstream: https://github.com/QwenLM/qwen-code
#
# Why this package exists rather than `pkgs.qwen-code`:
#   nixpkgs is BEHIND upstream, and this deployment needs the newer settings schema.
#   Checked 2026-08-11 on nixos-unstable: pkgs.qwen-code is 0.16.0, this is 0.21.1.
#   (The gap used to be far worse -- nixos-25.11 shipped 0.2.2, which predated the
#   entire schema: no `modelProviders`, no `permissions`, no `context.fileName`, only
#   the old OPENAI_BASE_URL/OPENAI_MODEL env vars. 0.21.1 has `modelProviders` +
#   `security.auth.selectedType` + `permissions.allow` + `mcpServers.*.httpUrl`, all
#   of which modules/qwen-code.nix uses.)
#
#   DELETE THIS FILE when `pkgs.qwen-code` reaches 0.21.1 or later -- compare against
#   the version below, not against any number written in this comment. Note the
#   direction: nixpkgs being merely NEWER than 0.2.2 is not the bar, and reading a
#   stale comment that way would downgrade the machine.
#
# Why the npm registry tarball rather than buildNpmPackage on the GitHub source:
#   the published npm package is already fully bundled by upstream's esbuild step —
#   it declares *zero* runtime dependencies, contains no native .node modules, and
#   ships its own vendored ripgrep. There is nothing left for npm to resolve, so
#   buildNpmPackage would only add an npmDepsHash to churn on every version bump
#   (and nixpkgs' expression already has to patch node-pty/keytar out of the
#   lockfile to build at all). This is a plain unpack-and-wrap instead.
let
  version = "0.21.1";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "qwen-code";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@qwen-code/qwen-code/-/qwen-code-${version}.tgz";
    hash = "sha256-dcA23NeDhMm9Gangev2AIia7g1Me80pj+PoUo2Ka4vs=";
  };

  nativeBuildInputs = [ pkgs.makeWrapper ];

  # The tarball's single top-level `package/` directory is stripped by the default
  # unpackPhase, so the build dir is already the package root.
  dontConfigure = true;
  dontBuild = true;

  # vendor/ripgrep/x64-linux/rg is a static-pie ELF (verified with file(1)), so it
  # needs no patchelf and no interpreter fixup — leave the tree byte-identical to
  # what upstream published. Nothing else in the closure is a dynamic executable,
  # hence stdenvNoCC.
  dontPatchELF = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/qwen-code
    cp -r . $out/share/qwen-code/

    # bin.qwen is cli-entry.js, an ESM module with a `#!/usr/bin/env node` shebang.
    # Invoking node explicitly (rather than patchShebangs + a symlink) is what pins
    # the interpreter: package.json declares engines.node >= 22, so nodejs_22 is
    # named outright instead of tracking whatever pkgs.nodejs happens to be.
    makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/qwen \
      --add-flags $out/share/qwen-code/cli-entry.js \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git ]}

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Agentic coding CLI from the Qwen team (gemini-cli fork)";
    homepage = "https://github.com/QwenLM/qwen-code";
    license = licenses.asl20;
    mainProgram = "qwen";
    platforms = [ "x86_64-linux" ];
  };
}
