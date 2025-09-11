{ config, pkgs, ... }:

{
  home.packages = [
    # MinGW cross-compiler for building Windows executables
    pkgs.pkgsCross.mingwW64.stdenv.cc
    
    (pkgs.writeShellScriptBin "mo2" ''
      #!/usr/bin/env bash
      
      set -euo pipefail
      
      # Configuration
      SCRIPT_NAME="mo2"
      CACHE_DIR="$HOME/.cache/mo2-installer"
      SHARED_DIR="$HOME/.local/share/modorganizer2"
      LOG_FILE="$CACHE_DIR/install_$(date +"%Y%m%d_%H%M%S").log"
      
      # URLs and checksums
      MO2_URL="https://github.com/ModOrganizer2/modorganizer/releases/download/v2.5.2/Mod.Organizer-2.5.2.7z"
      MO2_SHA256="e6376efd87fd5ddd95aee959405e8f067afa526ea6c2c0c5aa03c5108bf4a815"
      JDK_URL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u312-b07/OpenJDK8U-jre_x64_windows_hotspot_8u312b07.zip"
      WINETRICKS_URL="https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
      
      # SkyrimSE configuration
      GAME_STEAM_SUBDIRECTORY="Skyrim Special Edition"
      GAME_NEXUSID="skyrimspecialedition"
      GAME_APPID="489830"
      GAME_EXECUTABLE="SkyrimSELauncher.exe"
      GAME_PROTONTRICKS=("xaudio2_7=native" "xact" "d3dcompiler_43" "vcrun2022")
      GAME_SCRIPTEXTENDER_URL="https://skse.silverlock.org/beta/skse64_2_02_06.7z"
      GAME_SCRIPTEXTENDER_FILES=(
        "skse64_2_02_06/Data"
        "skse64_2_02_06/skse64_1_6_1170.dll"
        "skse64_2_02_06/skse64_loader.exe"
      )
      
      # Create directories
      mkdir -p "$CACHE_DIR"
      mkdir -p "$SHARED_DIR"
      
      # Setup logging
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      # Logging functions
      log_info() {
        echo "INFO: $*" >&2
      }
      
      log_warn() {
        echo "WARN: $*" >&2
      }
      
      log_error() {
        echo "ERROR: $*" >&2
      }
      
      # Error handling
      handle_error() {
        log_error "Installation failed. Check $LOG_FILE for details."
        exit 1
      }
      
      trap handle_error ERR
      
      # Check if running as root
      if [ "$UID" == "0" ]; then
        log_error "Do not run as root"
        exit 1
      fi
      
      # Dependency checking
      check_dependencies() {
        local missing_deps=()
        
        if ! command -v 7z >/dev/null 2>&1; then
          missing_deps+=(p7zip)
        fi
        
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
          missing_deps+=("curl or wget")
        fi
        
        if ! command -v protontricks >/dev/null 2>&1; then
          missing_deps+=(protontricks)
        fi
        
        if ! command -v zenity >/dev/null 2>&1; then
          missing_deps+=(zenity)
        fi
        
        if [ ''${#missing_deps[@]} -gt 0 ]; then
          log_error "Missing dependencies: ''${missing_deps[*]}"
          log_error "Install them with: nix-env -iA nixpkgs.p7zip nixpkgs.protontricks nixpkgs.zenity nixpkgs.curl"
          exit 1
        fi
        
        log_info "All dependencies met"
      }
      
      # Download function
      download() {
        local url="$1"
        local output="$2"
        local progress_text="Downloading '$(basename "$output")'"
        
        log_info "Downloading $url to $output"
        
        if command -v wget >/dev/null 2>&1; then
          wget "$url" --progress=dot --verbose --show-progress -O "$output" 2>&1 | \
            stdbuf -o0 tr '[:cntrl:]' '\n' | \
            grep --color=never --line-buffered -oE '[0-9\.]+%' | \
            zenity --progress --auto-kill --auto-close --text="$progress_text" || true
        elif command -v curl >/dev/null 2>&1; then
          curl "$url" -o "$output" -# 2>&1 | \
            stdbuf -o0 tr '[:cntrl:]' '\n' | \
            grep --color=never --line-buffered -oE '[0-9\.]+%' | \
            zenity --progress --auto-kill --auto-close --text="$progress_text" || true
        else
          log_error "No download tool available"
          exit 1
        fi
      }
      
      # Extract function
      extract() {
        local archive="$1"
        local destination="$2"
        local progress_text="Extracting '$(basename "$archive")'"
        
        log_info "Extracting $archive to $destination"
        
        mkdir -p "$destination"
        
        7z x -bsp1 -bso0 -o"$destination" "$archive" | \
          stdbuf -o128 tr -d '\b' | \
          stdbuf -oL tr -s ' ' '\n' | \
          grep --line-buffered --color=never -oE '[0-9]+%' | \
          zenity --progress --auto-kill --auto-close --text="$progress_text" || true
      }
      
      # SHA256 validation
      validate_sha256() {
        local file="$1"
        local expected="$2"
        
        if [ ! -f "$file" ]; then
          return 1
        fi
        
        local actual
        actual=$(sha256sum "$file" | awk '{print $1}')
        
        if [ "$actual" != "$expected" ]; then
          log_info "Checksum mismatch for $file: expected $expected, got $actual. Removing file."
          rm -f "$file"
          return 1
        fi
        
        return 0
      }
      
      # Find Steam library
      find_steam_library() {
        local steam_dirs=(
          "$HOME/.steam/steam"
          "$HOME/.local/share/Steam"
          "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        )
        
        for steam_dir in "''${steam_dirs[@]}"; do
          if [ -d "$steam_dir" ]; then
            local library_folders="$steam_dir/steamapps/libraryfolders.vdf"
            if [ -f "$library_folders" ]; then
              while IFS= read -r line; do
                if [[ $line =~ \"path\"[[:space:]]*\"([^\"]+)\" ]]; then
                  local library_path="''${BASH_REMATCH[1]}"
                  local game_path="$library_path/steamapps/common/$GAME_STEAM_SUBDIRECTORY"
                  if [ -d "$game_path" ] && [ -f "$game_path/$GAME_EXECUTABLE" ]; then
                    echo "$library_path"
                    return 0
                  fi
                fi
              done < "$library_folders"
            fi
            
            # Fallback: check default location
            local default_game_path="$steam_dir/steamapps/common/$GAME_STEAM_SUBDIRECTORY"
            if [ -d "$default_game_path" ] && [ -f "$default_game_path/$GAME_EXECUTABLE" ]; then
              echo "$steam_dir"
              return 0
            fi
          fi
        done
        
        return 1
      }
      
      # Main installation function
      install_mo2() {
        log_info "Starting Mod Organizer 2 installation for Skyrim Special Edition"
        
        # Check dependencies
        check_dependencies
        
        # Use hardcoded paths for reliable reinstallation
        local steam_library="$HOME/.local/share/Steam"
        local game_installation="$steam_library/steamapps/common/$GAME_STEAM_SUBDIRECTORY"
        
        log_info "Using Steam library: $steam_library"
        log_info "Game installation: $game_installation"
        
        # Verify game exists (check for main game executable)
        if [ ! -d "$game_installation" ] || [ ! -f "$game_installation/SkyrimSE.exe" ]; then
          log_error "Skyrim Special Edition not found at: $game_installation"
          log_error "Make sure the game is installed through Steam"
          exit 1
        fi
        
        # Download files
        local downloaded_mo2="$CACHE_DIR/$(basename "$MO2_URL")"
        local downloaded_jdk="$CACHE_DIR/$(basename "$JDK_URL")"
        local downloaded_winetricks="$CACHE_DIR/winetricks"
        local downloaded_scriptextender="$CACHE_DIR/''${GAME_NEXUSID}_$(basename "$GAME_SCRIPTEXTENDER_URL")"
        
        # Download MO2 with checksum validation
        local mo2_attempts=0
        local mo2_max_attempts=3
        while ! validate_sha256 "$downloaded_mo2" "$MO2_SHA256"; do
          mo2_attempts=$((mo2_attempts + 1))
          if [ "$mo2_attempts" -ge "$mo2_max_attempts" ]; then
            log_error "Failed to download MO2 with correct checksum after $mo2_max_attempts attempts"
            exit 1
          fi
          log_info "Attempt $mo2_attempts: Downloading MO2..."
          rm -f "$downloaded_mo2"
          download "$MO2_URL" "$downloaded_mo2"
        done
        
        # Download other components
        if [ ! -f "$downloaded_jdk" ]; then
          download "$JDK_URL" "$downloaded_jdk"
        fi
        
        if [ ! -f "$downloaded_winetricks" ]; then
          download "$WINETRICKS_URL" "$downloaded_winetricks"
        fi
        
        if [ ! -f "$downloaded_scriptextender" ]; then
          download "$GAME_SCRIPTEXTENDER_URL" "$downloaded_scriptextender"
        fi
        
        # Extract files
        local extracted_mo2="$CACHE_DIR/mo2_extracted"
        local extracted_jdk="$CACHE_DIR/jdk_extracted"
        local extracted_scriptextender="$CACHE_DIR/scriptextender_extracted"
        
        if [ ! -d "$extracted_mo2" ]; then
          extract "$downloaded_mo2" "$extracted_mo2"
        fi
        
        if [ ! -d "$extracted_jdk" ]; then
          extract "$downloaded_jdk" "$extracted_jdk"
        fi
        
        if [ ! -d "$extracted_scriptextender" ]; then
          extract "$downloaded_scriptextender" "$extracted_scriptextender"
        fi
        
        # Setup Wine prefix
        local wine_prefix="$HOME/.local/share/Steam/steamapps/compatdata/$GAME_APPID/pfx"
        
        if [ ! -d "$wine_prefix" ]; then
          log_error "Wine prefix not found at $wine_prefix"
          log_error "Run Skyrim Special Edition at least once through Steam to create the prefix"
          exit 1
        fi
        
        log_info "Using Wine prefix: $wine_prefix"
        
        # Install MO2
        local mo2_install_dir="$wine_prefix/drive_c/Mod Organizer 2"
        log_info "Installing Mod Organizer 2 to: $mo2_install_dir"
        
        rm -rf "$mo2_install_dir"
        mkdir -p "$mo2_install_dir"
        cp -r "$extracted_mo2"/* "$mo2_install_dir/"
        
        # Install Java
        local java_install_dir="$wine_prefix/drive_c/java"
        log_info "Installing Java to: $java_install_dir"
        
        rm -rf "$java_install_dir"
        mkdir -p "$java_install_dir"
        cp -r "$extracted_jdk"/* "$java_install_dir/"
        
        # Install Script Extender (SKSE)
        log_info "Installing SKSE64..."
        for file in "''${GAME_SCRIPTEXTENDER_FILES[@]}"; do
          local src_path="$extracted_scriptextender/$file"
          local dst_path="$game_installation/$(basename "$file")"
          
          if [ -d "$src_path" ]; then
            cp -r "$src_path"/* "$game_installation/"
          elif [ -f "$src_path" ]; then
            cp "$src_path" "$dst_path"
          fi
        done
        
        # Install winetricks
        cp "$downloaded_winetricks" "$SHARED_DIR/winetricks"
        chmod +x "$SHARED_DIR/winetricks"
        
        # Setup Steam Redirector
        log_info "Setting up Steam redirector..."
        
        # No need to create modorganizer2 directory - path is hardcoded in redirector
        
        # Backup original game executable
        local original_executable="$game_installation/_$GAME_EXECUTABLE"
        local current_executable="$game_installation/$GAME_EXECUTABLE"
        
        if [ ! -f "$original_executable" ]; then
          log_info "Backing up original game executable"
          # Handle case where current executable is a symlink
          if [ -L "$current_executable" ]; then
            log_info "Current executable is a symlink, need to find original"
            # Look for the actual original executable in common locations
            local possible_originals=(
              "$game_installation/SkyrimSE.exe"
              "$(readlink "$current_executable")"
            )
            for orig in "''${possible_originals[@]}"; do
              if [ -f "$orig" ] && [ ! -L "$orig" ]; then
                log_info "Found original executable: $orig"
                cp "$orig" "$original_executable"
                break
              fi
            done
          else
            cp "$current_executable" "$original_executable"
          fi
        fi
        
        # Remove any existing symlink or file
        if [ -e "$current_executable" ]; then
          log_info "Removing existing executable/symlink"
          rm -f "$current_executable"
        fi
        
        # Create simplified C source for Windows redirector
        log_info "Creating C redirector source"
        cat > "$CACHE_DIR/redirector.c" << EOF
#include <windows.h>
#include <stdio.h>

int main() {
    // Hardcoded MO2 path
    LPCWSTR mo2Path = L"Z:\\\\home\\\\$USER\\\\.local\\\\share\\\\Steam\\\\steamapps\\\\compatdata\\\\489830\\\\pfx\\\\drive_c\\\\Mod Organizer 2\\\\ModOrganizer.exe";
    
    // Create process information structures
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    
    // Launch MO2
    if (CreateProcessW(mo2Path, NULL, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) {
        // Wait for MO2 to finish
        WaitForSingleObject(pi.hProcess, INFINITE);
        
        // Clean up
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return 0;
    } else {
        printf("Failed to launch MO2: %lu\\n", GetLastError());
        return 1;
    }
}
EOF

        # Build Windows executable using MinGW cross-compiler
        log_info "Building Windows redirector executable"
        
        if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
          log_error "MinGW cross-compiler not found. Please install: nix-env -iA nixpkgs.pkgsCross.mingwW64.stdenv.cc"
          exit 1
        fi
        
        # Cross-compile to Windows (simple approach)
        (cd "$CACHE_DIR" && x86_64-w64-mingw32-gcc -o redirector.exe redirector.c -s -O2 -mwindows)
        
        if [ ! -f "$CACHE_DIR/redirector.exe" ]; then
          log_error "Failed to build C redirector"
          exit 1
        fi
        
        # Copy the compiled redirector to the game directory
        log_info "Installing C redirector as game executable"
        cp "$CACHE_DIR/redirector.exe" "$current_executable"
        
        # Create the log directory structure
        mkdir -p "$HOME/.local/share/mod-organizer-2"
        
        # Register installation
        log_info "Registering MO2 installation..."
        mkdir -p "$HOME/.config/modorganizer2/instances"
        rm -f "$HOME/.config/modorganizer2/instances/$GAME_NEXUSID"
        ln -s "$mo2_install_dir" "$HOME/.config/modorganizer2/instances/$GAME_NEXUSID"
        
        # Run protontricks to install dependencies
        log_info "Installing Windows dependencies via protontricks..."
        for dep in "''${GAME_PROTONTRICKS[@]}"; do
          log_info "Installing $dep..."
          protontricks "$GAME_APPID" "$dep" || log_warn "Failed to install $dep"
        done
        
        log_info "Installation completed successfully!"
        log_info "Launch Skyrim Special Edition through Steam to use Mod Organizer 2"
        
        if command -v zenity >/dev/null 2>&1; then
          zenity --info --text="Installation successful!\n\nLaunch Skyrim Special Edition on Steam to use Mod Organizer 2"
        fi
      }
      
      # Help function
      show_help() {
        cat << EOF
Mod Organizer 2 Installer for Skyrim Special Edition

Usage: $SCRIPT_NAME [OPTIONS]

Options:
  -h, --help     Show this help message
  -v, --version  Show version information
  
This script installs Mod Organizer 2 for Skyrim Special Edition on Linux.

Requirements:
- Skyrim Special Edition installed via Steam
- protontricks
- p7zip
- zenity
- curl or wget

The script will:
1. Check for dependencies
2. Find your Skyrim Special Edition installation
3. Download and install Mod Organizer 2
4. Install SKSE64 (Script Extender)
5. Configure the Wine prefix with necessary dependencies

After installation, launch Skyrim Special Edition through Steam to use Mod Organizer 2.
EOF
      }
      
      # Parse command line arguments
      case "''${1:-}" in
        -h|--help)
          show_help
          exit 0
          ;;
        -v|--version)
          echo "$SCRIPT_NAME 1.0.0 - Skyrim SE Mod Organizer 2 Installer"
          exit 0
          ;;
        "")
          install_mo2
          ;;
        *)
          log_error "Unknown option: $1"
          show_help
          exit 1
          ;;
      esac
    '')
  ];
}