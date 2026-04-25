{ pkgs, config, ... }:

{
  services.wivrn = {
    enable = true;
    openFirewall = true;       # TCP+UDP port 9757
    highPriority = true;       # CAP_SYS_NICE for async reprojection
    autoStart = true;

    # Expose WiVRn OpenXR runtime inside Steam's Pressure Vessel sandbox
    steam.importOXRRuntimes = true;

    # Force compositor to use NVIDIA GPU (GPU1 in Vulkan enumeration).
    # Intel Arc (GPU0) has a buggy GL_EXT_memory_object_fd implementation
    # that crashes with native OpenGL games, and cross-GPU swapchain sharing
    # causes green line artifacts when compositor and game are on different GPUs.
    monadoEnvironment = {
      XRT_COMPOSITOR_FORCE_GPU_INDEX = "1";
    };
  };

  environment.systemPackages = [ pkgs.android-tools ];  # ADB for wired USB Quest 2 connection

  # OpenVR → OpenXR translation via xrizer (for SteamVR/OpenVR games)
  home-manager.users.sheath.xdg.configFile."openvr/openvrpaths.vrpath".text = builtins.toJSON {
    config = [ "${config.home-manager.users.sheath.xdg.dataHome}/Steam/config" ];
    external_drivers = null;
    jsonid = "vrpathreg";
    log = [ "${config.home-manager.users.sheath.xdg.dataHome}/Steam/logs" ];
    runtime = [ "${pkgs.xrizer}/lib/xrizer" ];
    version = 1;
  };
  home-manager.users.sheath.xdg.configFile."openvr/openvrpaths.vrpath".force = true;

  # WiVRn server configuration
  #
  # Per-game Steam settings (not managed by NixOS):
  #   1. Force Proton: Right-click game → Properties → Compatibility
  #      → "Force the use of a specific Steam Play compatibility tool" → Proton Experimental
  #   2. Launch Options: Right-click game → Properties → Launch Options:
  #      DXVK_FILTER_DEVICE_NAME="NVIDIA" PRESSURE_VESSEL_FILESYSTEMS_RW=$XDG_RUNTIME_DIR/wivrn %command%
  #
  #   DXVK_FILTER_DEVICE_NAME ensures the game renders on NVIDIA (matching the compositor).
  #   PRESSURE_VESSEL_FILESYSTEMS_RW exposes the WiVRn IPC socket to the Pressure Vessel sandbox.
  #   Proton is required because native Linux OpenGL games crash on Intel Arc's GL_EXT_memory_object_fd;
  #   Proton uses DXVK (Vulkan) which avoids the broken OpenGL path entirely.
  home-manager.users.sheath.xdg.configFile."wivrn/config.json".text = builtins.toJSON {
    debug-gui = false;
    hid-forwarding = false;
    use-steamvr-lh = false;
    encoders = [
      {
        encoder = "nvenc";
        codec = "h265";
        width = 1.0;
        height = 1.0;
      }
    ];
  };
  home-manager.users.sheath.xdg.configFile."wivrn/config.json".force = true;
}
