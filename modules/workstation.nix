{ config, pkgs, lib, ... }: {
  imports = [ 
    ../modules/gnome.nix
    ../modules/sops.nix
    ../modules/dconf.nix
    ../modules/syncthing.nix
    ../modules/auto-update.nix
  ];
  # Common workstation applications that work with any desktop environment
  environment.systemPackages = with pkgs; [
    # Document creation and processing
    tectonic
    pandoc
    recoll
    evince
    
    # Communication and collaboration
    element-desktop
    signal-desktop
    discord
    thunderbird
    
    # Development tools
    hexo-cli
    gemini-cli
    git
    python3
    vscode
    aider-chat
    gnumake
    nodejs
    gcc
    parallel
    zstd
    
    # 3D printing and CAD
    prusa-slicer
    openscad
    
    # Note-taking and productivity
    obsidian 
    xournalpp
    
    # Multimedia
    mpv
    vlc
    pavucontrol
    freetube
    qbittorrent
  
    # System utilities
    keepassxc
    (appimage-run.override {
      extraPkgs = pkgs: [ pkgs.zstd ];
    })
    brasero
    ripgrep
    btop-cuda
    wget
    neovim
    zenity # terminal notifications
    p7zip
    sops
    age
    srm
    keyd
    evtest
    libinput
    mullvad-vpn
    
    # Gaming
    # blightmud  # temporarily disabled - build failure with gcc 15
    (lutris.override {
      extraLibraries = pkgs: [
        libgudev
        libvdpau
        libtheora
        speex
      ];
    })
    protonup-ng
    protontricks 
    #wine
    #wine64
    wineWow64Packages.waylandFull
    winetricks
    vulkan-loader
    vulkan-tools
    ffmpeg-full
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good  
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
    
    # Office suite
    libreoffice-fresh
    
    # Web browser
    google-chrome
    mullvad-browser
  ];

  # Programs
  programs.firefox.enable = true;

  # nix-ld for running dynamically linked executables (AppImages, etc.)
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
  
  # Services
  services.mullvad-vpn.enable = true;
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.epson-escpr2 ];

  # Avahi for network printer discovery (.local hostname resolution)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  services.flatpak.enable = true;


  services.pulseaudio.enable = false;
  security.rtkit.enable = true;

  # Bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true;  # Needed for battery reporting and better codec support
      };
    };
  };
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # Low-latency configuration for gaming
    extraConfig.pipewire."10-low-latency" = {
      "context.properties" = {
        "default.clock.rate" = 48000;
        "default.clock.quantum" = 256;
        "default.clock.min-quantum" = 256;
        "default.clock.max-quantum" = 512;
      };
    };
    # Bluetooth configuration for stable profile switching
    wireplumber.extraConfig."10-bluez" = {
      "monitor.bluez.properties" = {
        "bluez5.enable-sbc-xq" = true;
        "bluez5.enable-msbc" = true;
        "bluez5.enable-hw-volume" = true;
        "bluez5.roles" = [ "a2dp_sink" "a2dp_source" "bap_sink" "bap_source" "hsp_hs" "hsp_ag" "hfp_hf" "hfp_ag" ];
      };
    };
    # Disable auto-switching which can cause instability
    wireplumber.extraConfig."11-bluetooth-policy" = {
      "wireplumber.settings" = {
        "bluetooth.autoswitch-to-headset-profile" = false;
      };
    };
  };
  
  # Wayland support for Electron apps
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  #environment.sessionVariables.GST_PLUGIN_SYSTEM_PATH_1_0 = "/run/current-system/sw/lib/gstreamer-1.0";

  # Claude Code global configuration
  home-manager.users.sheath.home.file.".claude/CLAUDE.md".text = ''
    # CLAUDE.md — Global Configuration

    ## Identity

    You are an expert programmer assisting Sean Heath in implementing software and hardware projects and managing his NixOS systems. Communicate in a terse, technical style. No filler.

    ## Languages & Toolchains

    - **Primary:** Python, Rust, C/C++, Go, Nix
    - Use language-idiomatic conventions for formatting, naming, and style (e.g., `black`/PEP 8 for Python, `rustfmt`/`clippy` for Rust, `gofmt` for Go, K&R for C/C++)
    - Minimize external dependencies — prefer stdlib where reasonable

    ## Development Philosophy

    1. **ALWAYS PLAN.** ANY time you need to change code ensure you are working from a plan developed in plan mode. If there is not a plan that addresses the current problem ask the user if they want to enter /plan mode.
    2. **Functionality first.** Get working code, then iterate on error handling and security.
    3. **Security second.** Follow industry best practices (OWASP, CERT C, etc.) but never let security concerns block forward progress. Log security considerations for later review.
    4. **Test critical paths only.** Use language-appropriate frameworks (`pytest`, `#[test]`, `go test`, etc.). No test bloat.

    ## Documentation

    - **Inline comments:** Generous. Explain *why*, not just *what*. Include references to relevant docs, blog posts, RFCs, CVEs, or standards where applicable.
    - **Docstrings/doc comments:** Required on all public functions using language-appropriate format (Python docstrings, Rust `///` doc comments, Go godoc, Doxygen for C/C++).
    - **README.md:** Keep updated as the project develops. Reflects current state of the project.

    ## Project Structure

    - Use best-practice layouts for each language (e.g., `src/lib.rs` for Rust, Go module conventions, Python package layout, etc.)
    - **Always use Nix flakes.** Every project must have a `flake.nix` with a `devShell` so `nix develop` provides all dependencies.
    - **Always include a `Makefile`** with standard targets: `build`, `test`, `run`, `clean`, `lint`, `fmt`. Add project-specific targets as needed.

    ## Required Project Docs

    ### `docs/specification.md`
    - Living document. Contains the current project specification.
    - Update as features are added, requirements change, or scope evolves.

    ### `docs/log.md`
    - Decision log with rationale for every significant choice.
    - Format entries as:
      ```
      ## YYYY-MM-DD — Brief Title

      **Decision:** What was decided.
      **Rationale:** Why.
      **Alternatives considered:** What else was on the table.
      ```
    - **Development concerns** go here with TODO syntax:
      ```
      <!-- TODO:SECURITY — Description of the concern and remediation plan -->
      <!-- TODO:FEATURE — Description of the discussed feature -->
      ```
    - **General TODOs:**
      ```
      <!-- TODO — Description of pending work -->
      ```

    ## Git Workflow

    - **New features always start on a branch.** Name branches descriptively (e.g., `feat/parser-module`, `fix/buffer-overflow`).
    - **Never merge without my manual validation.** When a feature is ready for testing:
      1. Provide a concise walkthrough of how to test it manually.
      2. Wait for my explicit approval before merging.
    - **Commit messages:** Short, technical, imperative mood (e.g., `add MODBUS parser for holding registers`). No fluff.
    - **Never include "co-authored by Claude", "AI-generated", or similar strings in commits.**
    - **Commit, Push, Plan.** Whenever you finish implementing a plan, commit the changes, push the changes, and re-enter plan mode.

    ## Communication Rules

    - Be terse and technical. No preamble, no filler.
    - **Ambiguity:** Stop and ask, but always provide a recommendation.
    - **Refactoring:** Never refactor without my explicit approval.
    - **File deletion:** Always confirm before deleting any file.
    - **File structure changes:** Do not reorganize or rename files/directories without permission.
    - **Feedback requests:** Always include a recommended course of action when asking for my input.
  '';
  home-manager.users.sheath.home.file.".claude/CLAUDE.md".force = true;
}
