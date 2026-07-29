{ pkgs }:

# imjtool -- Jonathan Levin's firmware image tool. Closed source; upstream ships
# only prebuilt binaries, so this is a binary repack of the vendor tarball with
# the ELF64 build patched to nixpkgs libraries.
# Docs: http://newosxbook.com/tools/imjtool.html
#
# The Linux (ELF64) build is the Android/embedded-image variant -- ANDROID!
# bootimg, BOOTLDR!, sparse images, system.transfer.list, Huawei OTA, QCom FBPK,
# EFI SCAP, UEFI, Samsung TOC, DTBO, super.img -- with LZMA and Brotli support.
# (Apple IMG1-IMG4 handling lives in the MacOS build, which is not installed
# here; use nixpkgs `img4lib` / `img4tool` for .img4/.im4p work on Linux.)
#
# Caveats:
#   - The upstream URL is unversioned and mutable (Levin overwrites it in place),
#     so the sha256 below will break whenever he republishes. When that happens,
#     re-fetch, re-hash, and bump `version` to the new binaries/ mtime.
#   - Served over plain HTTP; the pinned hash is the only integrity guarantee.
#   - Open-source alternatives exist in nixpkgs if the pin becomes a maintenance
#     burden: `img4lib` and `img4tool`.
pkgs.stdenv.mkDerivation rec {
  pname = "imjtool";
  # Version string as reported by the binary itself ("ImjTool 1.2.1", built
  # 2020-05-06); upstream does not version the download URL.
  version = "1.2.1";

  src = pkgs.fetchurl {
    url = "http://newosxbook.com/tools/imjtool.tgz";
    sha256 = "sha256-HwCpHOvxR/r/UkGqqpbWi/bs4EC0q34jwx/VP2TSmEc=";
  };

  # Tarball has no top-level directory (Makefile + binaries/ at the root).
  sourceRoot = ".";

  # The tarball ships a Makefile that expects source (*.c) files Levin does not
  # distribute; there is nothing to compile, only the prebuilt binary to install.
  dontBuild = true;

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  # patchelf --print-needed imjtool.ELF64: libz.so.1, liblzma.so.5, libc.so.6
  buildInputs = [ pkgs.zlib pkgs.xz ];

  installPhase = ''
    runHook preInstall
    install -Dm755 binaries/imjtool.ELF64 $out/bin/imjtool
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Android/embedded firmware image inspection, extraction and creation tool";
    homepage = "http://newosxbook.com/tools/imjtool.html";
    license = licenses.unfree; # proprietary freeware, binary-only
    platforms = [ "x86_64-linux" ];
    mainProgram = "imjtool";
  };
}
