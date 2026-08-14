{ pkgs }:

# qwen-code, QwenLM's fork of gemini-cli. Upstream: https://github.com/QwenLM/qwen-code
#
# Exists because nixpkgs is BEHIND upstream and modules/qwen-code.nix needs the newer
# settings schema (modelProviders, permissions, context.fileName, mcpServers.*.httpUrl).
# DELETE THIS FILE once pkgs.qwen-code reaches the version below or later -- compare against
# `version` in this file, not against any number in this comment, and note the direction:
# nixpkgs merely being newer than some older release is not the bar.
#
# The npm registry tarball rather than buildNpmPackage on the source: the published package
# is already bundled by upstream's esbuild step, declares zero runtime dependencies, has no
# native modules and vendors its own ripgrep. There is nothing for npm to resolve, so
# buildNpmPackage would only add an npmDepsHash to churn on every bump.
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
