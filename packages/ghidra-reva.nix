{ pkgs }:

# Ghidra 12.1 with the ReVa extension baked in -- an MCP server inside Ghidra exposing
# decompilation and rename tools over streamable HTTP on localhost:8080.
# Upstream: https://github.com/cyberkaida/reverse-engineering-assistant
#
# This package exists because ReVa ships one prebuilt zip per exact Ghidra release and
# Ghidra rejects an extension whose version does not match the running application. v7.3.0
# covers up to 12.1 and has no asset for the 12.1.2 nixpkgs ships, so stock ghidra-bin would
# leave the extension unloadable -- do NOT read the version numbers and conclude this file
# is obsolete. Revisit when ReVa publishes a matching asset. Bump BOTH versions together.
#
# Overrides ghidra-bin, not ghidra: ghidra-bin is a plain fetchzip of the NSA's release
# build, so a bump is a URL and hash edit, while the source build carries a full gradle
# lock. nixpkgs' withExtensions framework is deliberately unused -- it relies on a patch
# that only exists on the source build.
#
# NOTE the URL below embeds a second, independent date (20260613) that does NOT track
# ghidraDate; a version bump means editing three strings, not two.
let
  ghidraVersion = "12.1";
  ghidraDate = "20260513";

  revaVersion = "7.3.0";
  # Prebuilt: no compilation, so this is an opaque zip unpacked at install time.
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
