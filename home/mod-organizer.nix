{ config, pkgs, lib, ... }:

let
  mo2Script = pkgs.writeShellScriptBin "mo2-manager" ''
    #!/usr/bin/env bash
    set -e

    MO2_PREFIX="$HOME/.local/share/mod-organizer-2"
    MO2_DOWNLOADS="$HOME/Downloads"
    MO2_VERSION="2.5.2"
    MO2_URL="https://github.com/ModOrganizer2/modorganizer/releases/download/v''${MO2_VERSION}/Mod.Organizer-''${MO2_VERSION}.exe"
    
    SKYRIM_PATH="$HOME/.local/share/Steam/steamapps/common/Skyrim Special Edition"
    SKYRIM_DOCS="$HOME/Documents/My Games/Skyrim Special Edition"
    
    function install_mo2() {
        echo "Installing Mod Organizer 2 v''${MO2_VERSION}..."
        
        # Create MO2 directory
        mkdir -p "$MO2_PREFIX"
        
        # Download MO2 installer if not present
        if [ ! -f "$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.exe" ]; then
            echo "Downloading MO2..."
            ${pkgs.wget}/bin/wget -O "$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.exe" "$MO2_URL"
        fi
        
        # Extract MO2 using 7z
        echo "Extracting MO2..."
        cd "$MO2_PREFIX"
        ${pkgs.p7zip}/bin/7z x -y "$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.exe"
        
        # Create wine prefix
        export WINEPREFIX="$MO2_PREFIX/wine"
        export WINEARCH=win64
        
        echo "Setting up Wine prefix..."
        ${pkgs.wineWowPackages.staging}/bin/wineboot -u
        
        # Install required Windows components
        echo "Installing .NET and Visual C++ runtimes..."
        ${pkgs.winetricks}/bin/winetricks -q dotnet48 vcrun2019 vcrun2022
        
        # Configure Wine for better compatibility
        ${pkgs.wineWowPackages.staging}/bin/winecfg -v win10
        
        echo "MO2 installation complete!"
    }
    
    function run_mo2() {
        export WINEPREFIX="$MO2_PREFIX/wine"
        export WINEARCH=win64
        
        # Set up environment for better performance
        export DXVK_HUD=0
        export WINE_FULLSCREEN_FSR=1
        export WINE_CPU_TOPOLOGY=4:2
        
        if [ ! -f "$MO2_PREFIX/ModOrganizer.exe" ]; then
            echo "MO2 not found. Please run: mo2-manager install"
            exit 1
        fi
        
        echo "Starting Mod Organizer 2..."
        cd "$MO2_PREFIX"
        ${pkgs.wineWowPackages.staging}/bin/wine64 ModOrganizer.exe "$@"
    }
    
    function configure_mo2() {
        echo "Configuring MO2 for Skyrim SE..."
        
        # Create symlinks for easier mod management
        mkdir -p "$MO2_PREFIX/games"
        
        if [ -d "$SKYRIM_PATH" ]; then
            ln -sf "$SKYRIM_PATH" "$MO2_PREFIX/games/SkyrimSE"
            echo "Linked Skyrim SE installation"
        else
            echo "Warning: Skyrim SE not found at expected location"
        fi
        
        # Create directories for mods and profiles
        mkdir -p "$MO2_PREFIX/mods"
        mkdir -p "$MO2_PREFIX/profiles/Default"
        mkdir -p "$MO2_PREFIX/downloads"
        
        # Create initial ModOrganizer.ini with basic settings
        cat > "$MO2_PREFIX/ModOrganizer.ini" << EOF
    [General]
    gameName=Skyrim Special Edition
    gamePath=$SKYRIM_PATH
    language=en_US
    
    [Settings]
    download_directory=$MO2_PREFIX/downloads
    mod_directory=$MO2_PREFIX/mods
    profiles_directory=$MO2_PREFIX/profiles
    overwrite_directory=$MO2_PREFIX/overwrite
    
    [Display]
    show_tutorial=false
    EOF
        
        echo "Configuration complete!"
        echo "When MO2 starts, you may need to:"
        echo "1. Select Skyrim Special Edition as your game"
        echo "2. Point it to: $SKYRIM_PATH"
        echo "3. Configure SKSE64 if you plan to use it"
    }
    
    function install_skse() {
        echo "Installing SKSE64..."
        SKSE_VERSION="2.2.6"
        SKSE_URL="https://skse.silverlock.org/beta/skse64_''${SKSE_VERSION}.7z"
        
        # Download SKSE
        if [ ! -f "$MO2_DOWNLOADS/skse64_''${SKSE_VERSION}.7z" ]; then
            echo "Downloading SKSE64..."
            ${pkgs.wget}/bin/wget -O "$MO2_DOWNLOADS/skse64_''${SKSE_VERSION}.7z" "$SKSE_URL"
        fi
        
        # Extract to Skyrim directory
        cd "$SKYRIM_PATH"
        ${pkgs.p7zip}/bin/7z x -y "$MO2_DOWNLOADS/skse64_''${SKSE_VERSION}.7z" "skse64_''${SKSE_VERSION}/*"
        
        # Move files to correct locations
        mv "skse64_''${SKSE_VERSION}"/skse64_*.dll .
        mv "skse64_''${SKSE_VERSION}"/skse64_loader.exe .
        mkdir -p Data/Scripts
        mv "skse64_''${SKSE_VERSION}"/Data/Scripts/* Data/Scripts/
        rm -rf "skse64_''${SKSE_VERSION}"
        
        echo "SKSE64 installed successfully!"
    }
    
    case "$1" in
        install)
            install_mo2
            ;;
        run)
            shift
            run_mo2 "$@"
            ;;
        configure)
            configure_mo2
            ;;
        skse)
            install_skse
            ;;
        help|*)
            echo "Mod Organizer 2 Manager for NixOS"
            echo ""
            echo "Usage: mo2-manager [command]"
            echo ""
            echo "Commands:"
            echo "  install    - Download and install MO2"
            echo "  configure  - Configure MO2 for Skyrim SE"
            echo "  run        - Run MO2"
            echo "  skse       - Install SKSE64 for Skyrim SE"
            echo "  help       - Show this help message"
            echo ""
            echo "Typical first-time setup:"
            echo "  1. mo2-manager install"
            echo "  2. mo2-manager configure"
            echo "  3. mo2-manager skse (optional)"
            echo "  4. mo2-manager run"
            ;;
    esac
  '';

  mo2Desktop = pkgs.makeDesktopItem {
    name = "mod-organizer-2";
    exec = "${mo2Script}/bin/mo2-manager run";
    icon = "mod-organizer-2";
    desktopName = "Mod Organizer 2";
    comment = "Mod manager for Skyrim SE and other games";
    categories = [ "Game" ];
  };
in
{
  home.packages = [
    mo2Script
    mo2Desktop
  ];

  # Create initial directories
  home.activation.mo2Setup = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p $HOME/.local/share/mod-organizer-2
    mkdir -p $HOME/Documents/My\ Games/Skyrim\ Special\ Edition
  '';
}