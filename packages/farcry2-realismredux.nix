# Far Cry 2: Realism+Redux v1.2.5 (Nexus Mods #326) — "Original Colors, no player
# position" variant. A DX9-ONLY total overhaul merging Realism+ (Tom), Redux (Hunter),
# Multi-Fixer (FoxAhead) and Functional Outposts (Scubrah).
# Upstream: ModDB "Far Cry 2: Realism + Redux" / Nexus Mods #326.
#
# The download is a COMPLETE, self-contained overlay. Per the bundled install
# instructions ("Copy the 'bin' and 'Data_Win32' folders into your Far Cry 2
# directory"), it already ships the Multi-Fixer PRE-RENAMED for the Steam launch
# trick — so there is no separate Multi-Fixer fetch:
#   Data_Win32/{patch.dat,patch.fat}   the overhaul data
#   bin/FarCry2.exe                    the Multi-Fixer launcher (renamed; Steam runs this)
#   bin/farcry2game.exe                thin bootstrapper that loads the game's Dunia.dll
#   bin/FarCry2MF.dll                  the Multi-Fixer runtime
#   bin/FarCry2.ini                    FOV / no-blinking-items tweaks
# This derivation exposes that whole tree (minus the PDF) for fc2-apply-mods to overlay.
#
# Download-gated (Nexus), so it cannot be fetchurl'd. Seeded into the store once via
# requireFile. If missing (fresh machine, wiped /nix, GC) the build fails printing the
# re-seed command below — the intended "reinstall reminder". See docs/farcry2.md.
#
#   nix-store --add-fixed sha256 FC2-RealismPlusRedux-326-v1.2.5.7z
#
# The Nexus filename has spaces; seed a copy renamed to the `name` below (store paths
# forbid spaces). sha256 via: nix hash file <archive>
{ pkgs }:

let
  version = "1.2.5";
  src = pkgs.requireFile {
    name = "FC2-RealismPlusRedux-326-v1.2.5.7z";
    url = "https://www.nexusmods.com/farcry2/mods/326?tab=files";
    sha256 = "sha256-X3zot6BpxFmXilDHC1Uu8J1/gZEg+JGRTghD0PqDEi0=";
  };
in
pkgs.stdenv.mkDerivation {
  pname = "farcry2-realismredux";
  inherit version src;

  nativeBuildInputs = [ pkgs.p7zip ];
  dontUnpack = true;

  # Extract and expose the exact bin/ + Data_Win32/ overlay the mod author ships.
  # Sanity-check that the two overhaul data files are present so a bad/renamed
  # archive fails loudly rather than installing a partial overlay.
  installPhase = ''
    runHook preInstall
    7z x -o"$out" "$src" >/dev/null
    rm -f "$out"/*.pdf
    if [ ! -f "$out/Data_Win32/patch.dat" ] || [ ! -f "$out/Data_Win32/patch.fat" ]; then
      echo "error: archive missing Data_Win32/patch.{dat,fat}" >&2
      find "$out" -type f >&2
      exit 1
    fi
    runHook postInstall
  '';
}
