{ pkgs }:

pkgs.appimageTools.wrapType2 {
  pname = "jackify";
  version = "0.2.1.1";

  src = pkgs.fetchurl {
    url = "https://github.com/Omni-guides/Jackify/releases/download/v0.2.1.1/Jackify.AppImage";
    sha256 = "cd5adea2661a61f394ea9114959cfead53237ae4d904acf2954305d42a2611d4";
  };

  extraPkgs = pkgs: with pkgs; [
    zstd
  ];
}
