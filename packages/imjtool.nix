{ pkgs }:

# imjtool -- Jonathan Levin's Android/embedded firmware image tool. Closed
# source; upstream ships only prebuilt binaries, so this is a binary repack of
# the vendor tarball with the ELF build patched to nixpkgs libraries.
# Docs: http://newandroidbook.com/tools/imjtool.html
#
# NOTE: the tool moved from newosxbook.com to newandroidbook.com; the old
# newosxbook.com/tools/imjtool.tgz is frozen at v1.2.1 (2020) and lacks ZIP,
# XZ, BZ2, LZ4, PBZX/AA/YAA/LZFSE, IMG4, CrAu, MTK and FBPTv2 support. Do not
# revert to that URL.
#
# Handles: ANDROID! bootimg (hdr v0-v4) + vendor_boot, BOOTLDR!, sparse images,
# system.transfer.list, Huawei OTA, QCom FBPK/FBPTv2, EFI SCAP, UEFI, Samsung
# TOC, DTBO, super.img (unpack + pack), uImage, MTK, Spreadtrum PAC, AVB/vbmeta,
# CrAu, ZIP (incl. partial), and Apple PBZX/AA/YAA/LZFSE/IMG4/FTAB for IPSW and
# T2 firmware work.
#
# Caveats:
#   - The upstream URL is unversioned and mutable (Levin overwrites it in place),
#     so the sha256 below will break whenever he republishes. When that happens,
#     re-fetch, re-hash, and bump `version` from the new binaries/about.txt.
#   - Served over plain HTTP; the pinned hash is the only integrity guarantee.
let
  # Vendor tarball carries builds for several targets; pick by host platform.
  binaryFor = {
    x86_64-linux = "imjtool.ELF64.x64";
    aarch64-linux = "imjtool.ELF64.aarch64";
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "imjtool";
  # Version per the bundled about.txt changelog; that build is dated 2026-03-04.
  version = "2.0.3";

  src = pkgs.fetchurl {
    url = "http://newandroidbook.com/tools/imjtool.tgz";
    sha256 = "sha256-p2abZuUD3uC8pF62+Ys8J4AdTWQPYMBrOEvykxhi8eQ=";
  };

  # Tarball has no top-level directory (about.txt, LICENSE, binaries/ at root).
  sourceRoot = ".";

  # Prebuilt binaries only -- nothing to compile.
  dontBuild = true;

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  # patchelf --print-needed: libz, liblz4, liblzma, libbz2, libc
  buildInputs = [ pkgs.zlib pkgs.lz4 pkgs.xz pkgs.bzip2 ];

  installPhase = ''
    runHook preInstall
    install -Dm755 binaries/${binaryFor.${pkgs.stdenv.hostPlatform.system}} $out/bin/imjtool
    install -Dm444 LICENSE $out/share/doc/${pname}/LICENSE
    install -Dm444 about.txt $out/share/doc/${pname}/about.txt
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Android/embedded firmware image inspection, extraction and creation tool";
    homepage = "http://newandroidbook.com/tools/imjtool.html";
    license = licenses.unfree; # proprietary freeware, binary-only
    platforms = builtins.attrNames binaryFor;
    mainProgram = "imjtool";
  };
}
