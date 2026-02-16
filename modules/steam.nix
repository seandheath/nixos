{ config, pkgs, ... }:{
  programs.gamescope.enable = true;
  programs.gamemode.enable = true;
  programs.steam = {
    enable = true;
    protontricks.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
    package = pkgs.steam.override {
      extraPkgs = pkgs: with pkgs; [
        # 64-bit
        freetype
        fontconfig
        
        # 32-bit (critical for Wine)
        pkgsi686Linux.freetype
        pkgsi686Linux.fontconfig
      ];
    };
  };
  environment.systemPackages = with pkgs; [
    (heroic.override { extraPkgs = pkgs: [ pkgs.gamescope ]; })
    mumble
    (pkgs.writeShellScriptBin "steam-winetricks" ''
set -e

usage() {
  echo "Usage: steam-winetricks <steam-app-id> <winetricks-verbs...>"
  echo ""
  echo "Install Wine components into a Steam game's prefix."
  echo ""
  echo "Examples:"
  echo "  steam-winetricks 22380 vcrun2022 xact d3dx9"
  echo "  steam-winetricks 22380 --gui"
  echo "  steam-winetricks 489830 dotnet48 vcrun2019"
  echo ""
  echo "Common verbs:"
  echo "  vcrun2022, vcrun2019, vcrun2015  - Visual C++ runtimes"
  echo "  dotnet48, dotnet40               - .NET frameworks"  
  echo "  d3dx9, d3dx10, d3dx11            - DirectX libraries"
  echo "  xact, xact_x64                   - Xbox audio"
  echo "  physx                            - PhysX runtime"
  echo "  corefonts                        - Microsoft fonts"
  echo "  --gui                            - Open winetricks GUI"
  echo ""
  echo "Find app IDs at: https://steamdb.info/"
  exit 1
}

if [ $# -lt 2 ]; then
  usage
fi

APP_ID="$1"
shift
VERBS="$@"

# Support both common prefix locations
if [ -d "/home/$USER/.local/share/Steam/steamapps/compatdata/$APP_ID/pfx" ]; then
  WINEPREFIX="/home/$USER/.local/share/Steam/steamapps/compatdata/$APP_ID/pfx"
elif [ -d "/home/$USER/.steam/steam/steamapps/compatdata/$APP_ID/pfx" ]; then
  WINEPREFIX="/home/$USER/.steam/steam/steamapps/compatdata/$APP_ID/pfx"
else
  echo "Error: Wine prefix for app $APP_ID not found."
  echo "Make sure you've run the game at least once through Steam."
  exit 1
fi

echo "App ID: $APP_ID"
echo "Prefix: $WINEPREFIX"
echo "Verbs:  $VERBS"
echo ""

# Cleanup stale Wine processes
echo "Cleaning up stale Wine processes..."
pkill -9 wineserver 2>/dev/null || true
rm -f /dev/shm/wine-*-fsync 2>/dev/null || true
sleep 1

export WINEPREFIX
export WINEARCH=win64

echo "Running winetricks..."
${pkgs.steam-run}/bin/steam-run ${pkgs.winetricks}/bin/winetricks --force -q $VERBS

echo ""
echo "Done!"
    '')
  ];
}
