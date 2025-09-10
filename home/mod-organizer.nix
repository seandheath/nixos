{ config, pkgs, lib, ... }:

let
  nxmHandler = pkgs.writeShellScriptBin "mo2-nxm-handler" ''
    #!/usr/bin/env bash
    # NXM link handler for Mod Organizer 2
    
    MO2_PREFIX="$HOME/.local/share/mod-organizer-2"
    export WINEPREFIX="$MO2_PREFIX/wine"
    export WINEARCH=win64
    
    # Log for debugging
    echo "$(date): Handling NXM URL: $1" >> "$HOME/.local/share/mod-organizer-2/nxm-handler.log"
    
    # Check if MO2 is installed
    if [ ! -f "$MO2_PREFIX/ModOrganizer.exe" ]; then
        ${pkgs.libnotify}/bin/notify-send "MO2 Not Found" "Please install Mod Organizer 2 first"
        exit 1
    fi
    
    # Check if MO2 is already running
    if pgrep -f "ModOrganizer.exe" > /dev/null; then
        echo "MO2 is already running, sending URL..." >> "$HOME/.local/share/mod-organizer-2/nxm-handler.log"
        # MO2 should handle the URL when already running
        ${pkgs.wineWowPackages.staging}/bin/wine "$MO2_PREFIX/nxmhandler.exe" "$1"
    else
        echo "Starting MO2 with URL..." >> "$HOME/.local/share/mod-organizer-2/nxm-handler.log"
        cd "$MO2_PREFIX"
        ${pkgs.wineWowPackages.staging}/bin/wine ModOrganizer.exe "$1"
    fi
  '';

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
        local mo2_file="$1"
        
        # If no argument provided, check default location
        if [ -z "$mo2_file" ]; then
            # Check for both .exe and .7z in default location
            if [ -f "$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.7z" ]; then
                mo2_file="$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.7z"
            elif [ -f "$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.exe" ]; then
                mo2_file="$MO2_DOWNLOADS/Mod.Organizer-''${MO2_VERSION}.exe"
            fi
        fi
        
        # Check if file exists
        if [ ! -f "$mo2_file" ]; then
            echo "Error: MO2 file not found at: $mo2_file"
            echo "Please provide the path to the MO2 installer (.exe) or archive (.7z)"
            echo "Usage: mo2-manager install /path/to/Mod.Organizer-''${MO2_VERSION}.[exe|7z]"
            exit 1
        fi
        
        echo "Installing Mod Organizer 2 from: $mo2_file"
        
        # Create MO2 directory
        mkdir -p "$MO2_PREFIX"
        
        # Check file extension and handle accordingly
        if [[ "$mo2_file" == *.7z ]]; then
            echo "Extracting MO2 from 7z archive..."
            cd "$MO2_PREFIX"
            ${pkgs.p7zip}/bin/7z x -y "$mo2_file"
        elif [[ "$mo2_file" == *.exe ]]; then
            echo "Copying MO2 executable..."
            cp "$mo2_file" "$MO2_PREFIX/ModOrganizer.exe"
        else
            echo "Error: Unsupported file type. Please provide a .exe or .7z file"
            exit 1
        fi
        
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
        ${pkgs.wineWowPackages.staging}/bin/wine ModOrganizer.exe "$@"
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
        mkdir -p "$MO2_PREFIX/overwrite"
        mkdir -p "$MO2_PREFIX/webcache"
        
        # Create initial ModOrganizer.ini with basic settings
        # Convert Linux paths to Wine paths (Z: drive)
        WINE_SKYRIM_PATH="Z:$SKYRIM_PATH"
        WINE_MO2_PREFIX="Z:$MO2_PREFIX"
        
        cat > "$MO2_PREFIX/ModOrganizer.ini" << EOF
    [General]
    gameName=Skyrim Special Edition
    gamePath=$WINE_SKYRIM_PATH
    language=en_US
    
    [Settings]
    download_directory=$WINE_MO2_PREFIX/downloads
    mod_directory=$WINE_MO2_PREFIX/mods
    profiles_directory=$WINE_MO2_PREFIX/profiles
    overwrite_directory=$WINE_MO2_PREFIX/overwrite
    
    [Display]
    show_tutorial=false
    EOF
        
        # Setup NXM handler
        echo "Setting up NXM link handler..."
        mkdir -p "$HOME/.local/share/applications"
        
        cat > "$HOME/.local/share/applications/mo2-nxm-handler.desktop" << EOF
    [Desktop Entry]
    Type=Application
    Name=Mod Organizer 2 NXM Handler
    Exec=${nxmHandler}/bin/mo2-nxm-handler %u
    Categories=Game;
    MimeType=x-scheme-handler/nxm;x-scheme-handler/nxm-protocol;
    NoDisplay=true
    Terminal=false
    EOF
        
        # Update MIME database
        ${pkgs.shared-mime-info}/bin/update-mime-database "$HOME/.local/share/mime" 2>/dev/null || true
        
        # Register as default handler for nxm protocol
        ${pkgs.xdg-utils}/bin/xdg-mime default mo2-nxm-handler.desktop x-scheme-handler/nxm
        ${pkgs.xdg-utils}/bin/xdg-mime default mo2-nxm-handler.desktop x-scheme-handler/nxm-protocol
        
        echo "Configuration complete!"
        echo "NXM handler registered - 'Download with manager' links should now work"
        echo ""
        echo "When MO2 starts, you may need to:"
        echo "1. Select Skyrim Special Edition as your game"
        echo "2. Point it to: $SKYRIM_PATH"
        echo "3. Configure SKSE64 if you plan to use it"
    }
    
    function install_skse() {
        local skse_archive="$1"
        
        # If no argument provided, try to find SKSE archive in downloads
        if [ -z "$skse_archive" ]; then
            # Look for any SKSE archive in downloads directory
            skse_archive=$(find "$MO2_DOWNLOADS" -name "skse64_*.7z" | head -1)
            if [ -z "$skse_archive" ]; then
                echo "Error: No SKSE64 archive found in $MO2_DOWNLOADS"
                echo "Please provide the path to the SKSE64 7z archive"
                echo "Usage: mo2-manager skse /path/to/skse64_archive.7z"
                exit 1
            fi
            echo "Found SKSE archive: $(basename "$skse_archive")"
        fi
        
        # Check if archive exists
        if [ ! -f "$skse_archive" ]; then
            echo "Error: SKSE64 archive not found at: $skse_archive"
            echo "Please provide the path to the SKSE64 7z archive"
            echo "Usage: mo2-manager skse /path/to/skse64_archive.7z"
            exit 1
        fi
        
        echo "Installing SKSE64 from: $skse_archive"
        
        # Extract to temporary directory first
        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"
        ${pkgs.p7zip}/bin/7z x -y "$skse_archive"
        
        # Find the extracted SKSE directory (handle different archive structures)
        SKSE_DIR=$(find . -name "skse64_*" -type d | head -1)
        if [ -z "$SKSE_DIR" ]; then
            echo "Error: Could not find SKSE directory in archive"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        echo "Updating MO2's SKSE version..."
        
        # Copy SKSE executables and DLLs to MO2 root
        echo "Copying SKSE executables..."
        cp "$SKSE_DIR"/skse64_*.dll "$MO2_PREFIX/" 2>/dev/null || true
        cp "$SKSE_DIR"/skse64_loader.exe "$MO2_PREFIX/" 2>/dev/null || true
        
        # Update MO2's Data/Scripts directory
        if [ -d "$SKSE_DIR/Data/Scripts" ]; then
            echo "Copying SKSE script files..."
            mkdir -p "$MO2_PREFIX/Data/Scripts"
            cp -r "$SKSE_DIR"/Data/Scripts/* "$MO2_PREFIX/Data/Scripts/" 2>/dev/null || true
        fi
        
        # Clean up
        rm -rf "$TEMP_DIR"
        
        echo "SKSE64 installed successfully to MO2!"
        echo ""
        echo "Files installed:"
        ls -la "$MO2_PREFIX"/skse64_*.dll "$MO2_PREFIX"/skse64_loader.exe 2>/dev/null || echo "Warning: Some SKSE files may not have been found"
        echo ""
        echo "To use SKSE in MO2:"
        echo "1. Launch MO2: mo2-manager run"
        echo "2. Add a new executable in MO2 pointing to skse64_loader.exe"
        echo "3. Set it as your default launcher for Skyrim SE"
    }
    
    case "$1" in
        install)
            install_mo2 "$2"
            ;;
        run)
            shift
            run_mo2 "$@"
            ;;
        configure)
            configure_mo2
            ;;
        skse)
            install_skse "$2"
            ;;
        help|*)
            echo "Mod Organizer 2 Manager for NixOS"
            echo ""
            echo "Usage: mo2-manager [command] [options]"
            echo ""
            echo "Commands:"
            echo "  install [file]   - Install MO2 from provided .exe or .7z file"
            echo "                     Example: mo2-manager install ~/Downloads/Mod.Organizer-2.5.2.7z"
            echo "  configure        - Configure MO2 for Skyrim SE"
            echo "  run              - Run MO2"
            echo "  skse [file]      - Install SKSE64 from provided .7z file"
            echo "                     Example: mo2-manager skse ~/Downloads/skse64_2_02_06.7z"
            echo "  help             - Show this help message"
            echo ""
            echo "Typical first-time setup:"
            echo "  1. Download MO2 from: https://github.com/ModOrganizer2/modorganizer/releases"
            echo "     (Either the .exe installer or .7z archive)"
            echo "  2. Download SKSE64 from: https://skse.silverlock.org/"
            echo "  3. mo2-manager install /path/to/Mod.Organizer-2.5.2.[exe|7z]"
            echo "  4. mo2-manager configure"
            echo "  5. mo2-manager skse /path/to/skse64_2.2.6.7z (optional)"
            echo "  6. mo2-manager run"
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
    nxmHandler
    mo2Desktop
  ];

  # Create initial directories
  home.activation.mo2Setup = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p $HOME/.local/share/mod-organizer-2
    mkdir -p $HOME/Documents/My\ Games/Skyrim\ Special\ Edition
  '';
}
