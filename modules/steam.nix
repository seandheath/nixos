{ pkgs, ... }:
{
  # Proper Bluetooth HID profile for Xbox One/Series/Elite controllers.
  # Stock hid_microsoft exposes BT pads as pointer devices, causing the left
  # stick to move the cursor in games. xpadneo replaces it with a gamepad-only
  # profile and adds rumble/trigger fixes.
  hardware.xpadneo.enable = true;

  # xpadneo consumes Xbox HID reports at the kernel level and re-emits them
  # via evdev/joystick only. SDL2's hidapi Xbox backend still grabs the raw
  # /dev/hidrawN node and waits for native Xbox protocol that never arrives,
  # so SDL apps (Cemu, etc.) enumerate the pad but receive no button events.
  # Disable just the Xbox hidapi backend so SDL falls back to evdev; PS4/PS5/
  # Switch hidapi support is left intact.
  environment.sessionVariables.SDL_JOYSTICK_HIDAPI_XBOX = "0";

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
        # The Binding of Isaac: Rebirth (native, appid 250900) links
        # libGLU.so.1, which the Steam runtime doesn't ship. Without it the
        # native binary dies at startup with "error while loading shared
        # libraries: libGLU.so.1". libGL/mesa GLU is separate from the driver.
        libGLU

        # 32-bit (critical for Wine)
        pkgsi686Linux.freetype
        pkgsi686Linux.fontconfig
        pkgsi686Linux.libGLU
      ];
    };
  };
  environment.systemPackages = with pkgs; [
    (heroic.override { extraPkgs = pkgs: [ pkgs.gamescope ]; })
    mumble
    # protontricks resolves the prefix from the appid itself; this only adds the stale
    # wineserver/fsync cleanup, which it does not do.
    (pkgs.writeShellScriptBin "steam-winetricks" ''
      set -e
      [ $# -ge 1 ] || { echo "usage: steam-winetricks <steam-app-id> <winetricks-verbs...|--gui>"; exit 1; }
      pkill -9 wineserver 2>/dev/null || true
      rm -f /dev/shm/wine-*-fsync 2>/dev/null || true
      exec protontricks "$@"
    '')
  ];

}
