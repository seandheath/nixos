# nix-ld, so generic dynamically-linked binaries run (AppImages, vendor CLIs).
{ pkgs, ... }:
{
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      zstd
      stdenv.cc.cc.lib
      zlib
      glib
      libGL
      libx11
      libxcursor
      libxrandr
      libxi
      libxkbcommon
      wayland
      fontconfig
      freetype
      dbus
    ];
  };
}
