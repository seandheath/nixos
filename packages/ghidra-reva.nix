{ pkgs }:

# Ghidra 12.1 with the ReVa (Reverse Engineering Assistant) extension baked in.
#
# ReVa is a Ghidra extension that runs an MCP server inside Ghidra, exposing
# decompilation/xref/rename/etc. as LLM tools over streamable HTTP (localhost:8080
# by default). Upstream: https://github.com/cyberkaida/reverse-engineering-assistant
#
# Why this package exists at all:
#   ReVa ships its extension zip built against ONE exact Ghidra release, and this
#   deployment needs the Ghidra that matches the ReVa below -- 12.1, not merely
#   ">= 12.0". The extension is a hard version match, not a floor.
#
#   The original reason was different and is now obsolete: nixos-25.11 pinned Ghidra
#   11.4.2 in both `ghidra` and `ghidra-bin`, below ReVa's 12.0 minimum. As of
#   2026-08-11 nixos-unstable ships ghidra-bin 12.1.2, which clears that floor -- so
#   do NOT read the old rationale and conclude this file can be deleted. It cannot:
#   ReVa 7.3.0 publishes no 12.1.2 asset, so stock ghidra-bin would leave the
#   extension unloadable. Revisit when ReVa releases an asset matching whatever
#   ghidra-bin has moved to, then drop this file and use the stock package.
#
# Why override `ghidra-bin` rather than `ghidra`:
#   `ghidra-bin` is a plain fetchzip of the NSA's release build, so a version bump
#   is a URL + hash edit. The source-built `ghidra` carries a full gradle dependency
#   lock (deps.json) that would have to be regenerated. nixpkgs' extension framework
#   (`ghidra.withExtensions` / `buildGhidraExtension`) is deliberately *not* used: it
#   relies on nixpkgs' NIX_GHIDRAHOME patch, which only exists on the source build.
#
# Why Ghidra 12.1 specifically, and not 12.1.2 (what nixpkgs master has):
#   Ghidra refuses to load an extension whose extension.properties `version=` does
#   not match the running application version. ReVa ships one prebuilt zip per
#   supported Ghidra release; v7.3.0 covers 12.0, 12.0.1-12.0.4 and 12.1 — there is
#   no 12.1.2 asset. 12.1 is therefore the newest Ghidra with an exact-match ReVa
#   build. Bump BOTH versions together, or the extension will silently be rejected.
let
  ghidraVersion = "12.1";
  ghidraDate = "20260513";

  revaVersion = "7.3.0";
  # Prebuilt extension: extension.properties + Module.manifest + lib/*.jar. No
  # compilation, so this is fetched as an opaque zip and unpacked at install time.
  revaSrc = pkgs.fetchurl {
    url = "https://github.com/cyberkaida/reverse-engineering-assistant/releases/download/v${revaVersion}/ghidra_${ghidraVersion}_PUBLIC_20260613_reverse-engineering-assistant.zip";
    hash = "sha256-rCYNj7g5Fos4G2Jgj9mAIuXQS5jkhjn3V0Mqj0JAa0U=";
  };
in
pkgs.ghidra-bin.overrideAttrs (old: {
  pname = "ghidra-reva";
  version = ghidraVersion;

  src = pkgs.fetchzip {
    url = "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${ghidraVersion}_build/ghidra_${ghidraVersion}_PUBLIC_${ghidraDate}.zip";
    hash = "sha256-LmesjJ+IcmhFHqLOfTkUP0BGFHaQAlpxU/CcLAD5vDU=";
  };

  nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.unzip ];

  # NOTE: postFixup, not postInstall. ghidra-bin's installPhase (nixpkgs
  # pkgs/tools/security/ghidra/default.nix) is a custom phase with no
  # `runHook postInstall`, so a postInstall attribute would silently never run.
  # fixupPhase is the stock one, so postFixup does fire — but ghidra-bin defines
  # its own (it creates $out/bin and wraps support/launch.sh with the JDK), hence
  # the append rather than a replace.
  postFixup = old.postFixup + ''
    unzip -q -d "$out/lib/ghidra/Ghidra/Extensions" ${revaSrc}

    # Ghidra creates a lock file next to each loaded extension. The store is
    # read-only, so pre-create it — same trick as nixpkgs' with-extensions.nix.
    touch "$out/lib/ghidra/Ghidra/Extensions/reverse-engineering-assistant/.dbDirLock"
  '';

  meta = old.meta // {
    description = "${old.meta.description}, with the ReVa MCP server extension";
  };
})
