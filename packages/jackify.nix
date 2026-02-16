{ pkgs }:

let
  pname = "jackify";
  version = "0.2.1.1";

  src = pkgs.fetchurl {
    url = "https://github.com/Omni-guides/Jackify/releases/download/v${version}/Jackify.AppImage";
    sha256 = "cd5adea2661a61f394ea9114959cfead53237ae4d904acf2954305d42a2611d4";
  };

  appimageContents = pkgs.appimageTools.extractType2 { inherit pname version src; };
in
pkgs.stdenv.mkDerivation {
  inherit pname version;

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/256x256/apps $out/opt

    # Copy extracted AppImage contents
    cp -r ${appimageContents}/* $out/opt/

    install -Dm444 ${appimageContents}/com.jackify.app.png $out/share/icons/hicolor/256x256/apps/com.jackify.app.png

    # Run the extracted AppRun with steam-run
    makeWrapper ${pkgs.steam-run}/bin/steam-run $out/bin/jackify \
      --add-flags "$out/opt/AppRun"

    cat > $out/share/applications/jackify.desktop << EOF
[Desktop Entry]
Name=Jackify
Comment=Linux-native Wabbajack modlist installer
Exec=$out/bin/jackify %u
Icon=com.jackify.app
Type=Application
Categories=Game;Utility;
Terminal=false
MimeType=x-scheme-handler/nxm;
EOF
  '';
}
