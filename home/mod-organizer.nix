{ config, pkgs, lib, ... }:

let
  # Skyrim SE Steam App ID
  skyrimAppId = "489830";
  
  # MO2 installation paths
  mo2Prefix = "$HOME/.local/share/mod-organizer-2";
  mo2Shared = "$HOME/.local/share/modorganizer2";
  steamPath = "$HOME/.local/share/Steam";
  skyrimPath = "${steamPath}/steamapps/common/Skyrim Special Edition";
  skyrimDocs = "$HOME/Documents/My Games/Skyrim Special Edition";
  
  # DXVK memory configuration for better performance
  dxvkConfig = pkgs.writeText "dxvk.conf" ''
    # DXVK configuration for Skyrim SE
    dxgi.maxFrameLatency = 1
    d3d11.constantBufferRangeCheck = True
    d3d11.relaxedBarriers = True
    dxvk.enableAsync = True
    dxvk.numCompilerThreads = 4
    dxvk.memoryAllocatorMode = 0
  '';

  # Steam redirector - helps MO2 launch games through Steam
  steamRedirector = pkgs.writeShellScriptBin "mo2-steam-redirector" ''
    #!/usr/bin/env bash
    set -e
    
    INSTANCE_PATH="${mo2Prefix}/instance_path.txt"
    LOG_FILE="${mo2Prefix}/steam-redirector.log"
    
    log() {
      echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG_FILE"
    }
    
    log "Steam redirector called with args: $*"
    
    if [ -z "$NO_REDIRECT" ] && [ -f "$INSTANCE_PATH" ]; then
      GAME_EXE=$(cat "$INSTANCE_PATH")
      log "Redirecting to: $GAME_EXE"
    else
      # Fallback to original launcher
      ORIGINAL_NAME="''${0##*/}"
      GAME_EXE="''${0%/*}/_''${ORIGINAL_NAME#mo2-}"
      log "Using fallback launcher: $GAME_EXE"
    fi
    
    if [ -x "$GAME_EXE" ]; then
      log "Executing: $GAME_EXE $*"
      exec "$GAME_EXE" "$@"
    else
      log "ERROR: Cannot execute: $GAME_EXE"
      ${pkgs.libnotify}/bin/notify-send "MO2 Error" "Cannot launch game: $GAME_EXE"
      exit 1
    fi
  '';

  # NXM link handler for Nexus Mods
  nxmHandler = pkgs.writeShellScriptBin "mo2-nxm-handler" ''
    #!/usr/bin/env bash
    set -e
    
    export WINEPREFIX="${mo2Prefix}/wine"
    export WINEARCH=win64
    LOG_FILE="${mo2Prefix}/nxm-handler.log"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Handling NXM URL: $1" >> "$LOG_FILE"
    
    if [ ! -f "${mo2Prefix}/ModOrganizer.exe" ]; then
      ${pkgs.libnotify}/bin/notify-send "MO2 Not Found" "Please install Mod Organizer 2 first"
      exit 1
    fi
    
    # Check if MO2 is already running
    if pgrep -f "ModOrganizer.exe" > /dev/null; then
      echo "MO2 running, sending URL..." >> "$LOG_FILE"
      ${pkgs.wineWowPackages.staging}/bin/wine "${mo2Prefix}/nxmhandler.exe" "$1"
    else
      echo "Starting MO2 with URL..." >> "$LOG_FILE"
      cd "${mo2Prefix}"
      ${pkgs.wineWowPackages.staging}/bin/wine ModOrganizer.exe "$1"
    fi
  '';

  # Main MO2 management script
  mo2Manager = pkgs.writeShellScriptBin "mo2" ''
    #!/usr/bin/env bash
    set -e
    
    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
    
    # Paths
    MO2_PREFIX="${mo2Prefix}"
    MO2_SHARED="${mo2Shared}"
    STEAM_PATH="${steamPath}"
    SKYRIM_PATH="${skyrimPath}"
    SKYRIM_DOCS="${skyrimDocs}"
    SKYRIM_APPID="${skyrimAppId}"
    
    # Wine environment
    export WINEPREFIX="$MO2_PREFIX/wine"
    export WINEARCH=win64
    export WINE_CPU_TOPOLOGY=4:2
    export DXVK_HUD=0
    export WINE_FULLSCREEN_FSR=1
    
    # Helper functions
    log() {
      echo -e "''${GREEN}[MO2]''${NC} $*"
    }
    
    error() {
      echo -e "''${RED}[ERROR]''${NC} $*" >&2
    }
    
    warn() {
      echo -e "''${YELLOW}[WARN]''${NC} $*"
    }
    
    info() {
      echo -e "''${BLUE}[INFO]''${NC} $*"
    }
    
    check_steam() {
      if ! pgrep -x "steam" > /dev/null; then
        warn "Steam is not running!"
        warn "MO2 needs Steam to be running for proper game detection."
        read -p "Start Steam now? [Y/n] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
          log "Starting Steam..."
          steam > /dev/null 2>&1 &
          
          # Wait for Steam to start
          local count=0
          while ! pgrep -x "steam" > /dev/null && [ $count -lt 30 ]; do
            sleep 1
            ((count++))
          done
          
          if pgrep -x "steam" > /dev/null; then
            log "Steam started successfully"
            sleep 3 # Give Steam time to fully initialize
          else
            error "Failed to start Steam"
            return 1
          fi
        fi
      else
        info "Steam is running"
      fi
      return 0
    }
    
    check_protontricks() {
      if command -v protontricks &> /dev/null; then
        return 0
      elif flatpak list 2>/dev/null | grep -q "com.github.Matoking.protontricks"; then
        return 0
      else
        warn "Protontricks not found. Install it for better Steam integration:"
        info "  nix-env -iA nixos.protontricks"
        info "  or add to your configuration.nix"
        return 1
      fi
    }
    
    setup_wine_prefix() {
      log "Setting up Wine prefix..."
      
      # Create Wine prefix
      ${pkgs.wineWowPackages.staging}/bin/wineboot -u
      
      # Configure Wine
      ${pkgs.wineWowPackages.staging}/bin/winecfg -v win10
      
      # Install dependencies
      log "Installing Windows dependencies..."
      ${pkgs.winetricks}/bin/winetricks -q \
        dotnet48 \
        vcrun2019 \
        vcrun2022 \
        d3dcompiler_47 \
        faudio \
        arial \
        corefonts
      
      # Configure registry for Steam
      log "Configuring Wine registry for Steam..."
      
      # Add Steam registry entries
      ${pkgs.wineWowPackages.staging}/bin/wine reg add "HKCU\\Software\\Valve\\Steam" /v "SteamPath" /d "Z:${steamPath}" /f
      ${pkgs.wineWowPackages.staging}/bin/wine reg add "HKCU\\Software\\Valve\\Steam" /v "SteamExe" /d "Z:${steamPath}/steam.sh" /f
      ${pkgs.wineWowPackages.staging}/bin/wine reg add "HKCU\\Software\\Valve\\Steam" /v "ActiveProcess" /t REG_DWORD /d 1 /f
      
      # Add Skyrim SE registry entries
      ${pkgs.wineWowPackages.staging}/bin/wine reg add "HKLM\\SOFTWARE\\WOW6432Node\\Bethesda Softworks\\Skyrim Special Edition" /v "Installed Path" /d "Z:${skyrimPath}" /f
      
      log "Wine prefix configured"
    }
    
    configure_steam_prefix() {
      log "Configuring Steam prefix for Skyrim SE..."
      
      if check_protontricks; then
        # Use protontricks if available
        if command -v protontricks &> /dev/null; then
          log "Using protontricks to configure prefix..."
          protontricks "$SKYRIM_APPID" --no-runtime winecfg
          protontricks "$SKYRIM_APPID" arial
          protontricks "$SKYRIM_APPID" fontsmooth=rgb
        elif flatpak list 2>/dev/null | grep -q "com.github.Matoking.protontricks"; then
          log "Using flatpak protontricks..."
          flatpak run com.github.Matoking.protontricks "$SKYRIM_APPID" --no-runtime winecfg
          flatpak run com.github.Matoking.protontricks "$SKYRIM_APPID" arial
          flatpak run com.github.Matoking.protontricks "$SKYRIM_APPID" fontsmooth=rgb
        fi
      fi
      
      # Create symlinks for Steam compatibility
      if [ -d "$STEAM_PATH/steamapps/compatdata/$SKYRIM_APPID" ]; then
        log "Linking Steam compatdata..."
        mkdir -p "$MO2_PREFIX/steam-compat"
        ln -sfn "$STEAM_PATH/steamapps/compatdata/$SKYRIM_APPID" "$MO2_PREFIX/steam-compat/$SKYRIM_APPID"
      fi
    }
    
    install_mo2() {
      local mo2_file="$1"
      
      if [ -z "$mo2_file" ]; then
        error "Please provide the MO2 installer file"
        info "Usage: mo2 install /path/to/Mod.Organizer-2.x.x.exe"
        info "   or: mo2 install /path/to/Mod.Organizer-2.x.x.7z"
        exit 1
      fi
      
      if [ ! -f "$mo2_file" ]; then
        error "File not found: $mo2_file"
        exit 1
      fi
      
      log "Installing Mod Organizer 2..."
      
      # Check Steam first
      check_steam || exit 1
      
      # Create directories
      mkdir -p "$MO2_PREFIX"
      mkdir -p "$MO2_SHARED"
      mkdir -p "$SKYRIM_DOCS"
      
      # Extract/Install MO2
      if [[ "$mo2_file" == *.7z ]]; then
        log "Extracting MO2 archive..."
        cd "$MO2_PREFIX"
        ${pkgs.p7zip}/bin/7z x -y "$mo2_file"
      elif [[ "$mo2_file" == *.exe ]]; then
        log "Running MO2 installer..."
        setup_wine_prefix
        cd "$MO2_PREFIX"
        ${pkgs.wineWowPackages.staging}/bin/wine "$mo2_file"
      else
        error "Unsupported file type. Use .exe or .7z"
        exit 1
      fi
      
      # Setup Wine prefix
      setup_wine_prefix
      
      # Configure Steam integration
      configure_steam_prefix
      
      # Create MO2 directories
      log "Creating MO2 directories..."
      mkdir -p "$MO2_PREFIX/mods"
      mkdir -p "$MO2_PREFIX/profiles/Default"
      mkdir -p "$MO2_PREFIX/downloads"
      mkdir -p "$MO2_PREFIX/overwrite"
      mkdir -p "$MO2_PREFIX/webcache"
      
      # Copy DXVK configuration
      cp ${dxvkConfig} "$MO2_PREFIX/dxvk.conf"
      
      # Setup Steam redirector
      log "Setting up Steam redirector..."
      if [ -f "$SKYRIM_PATH/SkyrimSELauncher.exe" ]; then
        mv "$SKYRIM_PATH/SkyrimSELauncher.exe" "$SKYRIM_PATH/_SkyrimSELauncher.exe" 2>/dev/null || true
        ln -sf ${steamRedirector}/bin/mo2-steam-redirector "$SKYRIM_PATH/SkyrimSELauncher.exe"
      fi
      
      # Create initial ModOrganizer.ini
      cat > "$MO2_PREFIX/ModOrganizer.ini" << EOF
    [General]
    gameName=Skyrim Special Edition
    gamePath=Z:${skyrimPath}
    language=en_US
    steamAppID=$SKYRIM_APPID
    
    [Settings]
    download_directory=Z:$MO2_PREFIX/downloads
    mod_directory=Z:$MO2_PREFIX/mods
    profiles_directory=Z:$MO2_PREFIX/profiles
    overwrite_directory=Z:$MO2_PREFIX/overwrite
    
    [Display]
    show_tutorial=false
    
    [Steam]
    username=
    appID=$SKYRIM_APPID
    steamPath=Z:${steamPath}
    EOF
      
      # Setup NXM handler
      log "Registering NXM handler..."
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
      
      # Register MIME types
      ${pkgs.xdg-utils}/bin/xdg-mime default mo2-nxm-handler.desktop x-scheme-handler/nxm
      ${pkgs.xdg-utils}/bin/xdg-mime default mo2-nxm-handler.desktop x-scheme-handler/nxm-protocol
      
      log "Installation complete!"
      info "You can now run MO2 with: mo2 run"
    }
    
    run_mo2() {
      if [ ! -f "$MO2_PREFIX/ModOrganizer.exe" ]; then
        error "MO2 not installed. Run: mo2 install /path/to/installer"
        exit 1
      fi
      
      # Check Steam
      check_steam || warn "Continuing without Steam (not recommended)"
      
      log "Starting Mod Organizer 2..."
      
      # Set instance path for redirector
      echo "$SKYRIM_PATH/SkyrimSE.exe" > "$MO2_PREFIX/instance_path.txt"
      
      cd "$MO2_PREFIX"
      ${pkgs.wineWowPackages.staging}/bin/wine ModOrganizer.exe "$@"
    }
    
    install_skse() {
      local skse_file="$1"
      
      if [ -z "$skse_file" ] || [ ! -f "$skse_file" ]; then
        error "Please provide the SKSE64 archive"
        info "Usage: mo2 skse /path/to/skse64_*.7z"
        exit 1
      fi
      
      log "Installing SKSE64..."
      
      # Extract to temp directory
      TEMP_DIR=$(mktemp -d)
      cd "$TEMP_DIR"
      ${pkgs.p7zip}/bin/7z x -y "$skse_file"
      
      # Find SKSE directory
      SKSE_DIR=$(find . -name "skse64_*" -type d | head -1)
      if [ -z "$SKSE_DIR" ]; then
        error "Could not find SKSE directory in archive"
        rm -rf "$TEMP_DIR"
        exit 1
      fi
      
      # Copy to Skyrim directory
      log "Installing SKSE to Skyrim directory..."
      cp "$SKSE_DIR"/*.dll "$SKYRIM_PATH/" 2>/dev/null || true
      cp "$SKSE_DIR"/*.exe "$SKYRIM_PATH/" 2>/dev/null || true
      
      if [ -d "$SKSE_DIR/Data" ]; then
        cp -r "$SKSE_DIR/Data" "$SKYRIM_PATH/" 2>/dev/null || true
      fi
      
      # Also copy to MO2 for management
      cp "$SKSE_DIR"/*.dll "$MO2_PREFIX/" 2>/dev/null || true
      cp "$SKSE_DIR"/*.exe "$MO2_PREFIX/" 2>/dev/null || true
      
      rm -rf "$TEMP_DIR"
      
      log "SKSE64 installed successfully!"
      info "Configure SKSE in MO2's executable list"
    }
    
    uninstall() {
      warn "This will remove MO2 and all mods. Are you sure? [y/N]"
      read -p "" -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Uninstalling MO2..."
        
        # Restore original Skyrim launcher
        if [ -L "$SKYRIM_PATH/SkyrimSELauncher.exe" ]; then
          rm "$SKYRIM_PATH/SkyrimSELauncher.exe"
          [ -f "$SKYRIM_PATH/_SkyrimSELauncher.exe" ] && \
            mv "$SKYRIM_PATH/_SkyrimSELauncher.exe" "$SKYRIM_PATH/SkyrimSELauncher.exe"
        fi
        
        # Remove MO2 directories
        rm -rf "$MO2_PREFIX"
        rm -rf "$MO2_SHARED"
        
        # Remove desktop entry
        rm -f "$HOME/.local/share/applications/mo2-nxm-handler.desktop"
        
        log "MO2 uninstalled"
      else
        log "Uninstall cancelled"
      fi
    }
    
    show_help() {
      cat << EOF
    Mod Organizer 2 Manager for NixOS
    
    Usage: mo2 [command] [options]
    
    Commands:
      install <file>  - Install MO2 from .exe or .7z file
      run             - Launch Mod Organizer 2
      skse <file>     - Install SKSE64 from .7z archive
      uninstall       - Remove MO2 and all mods
      help            - Show this help message
    
    Quick Start:
      1. Download MO2: https://github.com/ModOrganizer2/modorganizer/releases
      2. Download SKSE64: https://skse.silverlock.org/
      3. mo2 install ~/Downloads/Mod.Organizer-*.7z
      4. mo2 skse ~/Downloads/skse64_*.7z
      5. mo2 run
    
    The script will:
      - Detect and start Steam if needed
      - Configure Wine prefix with Steam integration
      - Setup NXM link handling for Nexus Mods
      - Configure DXVK for better performance
      - Create Steam redirector for proper game launching
    EOF
    }
    
    # Main command handling
    case "''${1:-help}" in
      install)
        install_mo2 "$2"
        ;;
      run)
        shift
        run_mo2 "$@"
        ;;
      skse)
        install_skse "$2"
        ;;
      uninstall)
        uninstall
        ;;
      help|--help|-h)
        show_help
        ;;
      *)
        error "Unknown command: $1"
        show_help
        exit 1
        ;;
    esac
  '';

  # Desktop entry for MO2
  mo2Desktop = pkgs.makeDesktopItem {
    name = "mod-organizer-2";
    exec = "${mo2Manager}/bin/mo2 run";
    icon = "mod-organizer-2";
    desktopName = "Mod Organizer 2";
    comment = "Mod manager for Skyrim SE";
    categories = [ "Game" ];
  };

in
{
  home.packages = with pkgs; [
    mo2Manager
    nxmHandler
    steamRedirector
    mo2Desktop
    
    # Dependencies
    wineWowPackages.staging
    winetricks
    protontricks
    p7zip
    xdg-utils
    libnotify
  ];

  # Create initial directories
  home.activation.mo2Setup = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p ${mo2Prefix}
    mkdir -p ${mo2Shared}
    mkdir -p "$HOME/Documents/My Games/Skyrim Special Edition"
  '';
}