# Cemu (Wii U emulator) — native Linux build for single-player titles like BOTW.
# Online-play titles need the Lutris/Wine path; not configured here.
{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    cemu
    mangohud  # FPS / frametime overlay; useful for tuning FPS++ on BOTW
  ];

  # Vulkan, gamepad SDL2 support, low-latency Pipewire and GameMode are all
  # provided by steam.nix / workstation.nix / hosts/sulphur.nix already, so no
  # additional system config is needed here.
  #
  # Recommended launch:
  #   gamemoderun mangohud cemu
  #
  # First-run setup is manual and requires files dumped from the user's own
  # Wii U via https://dumplingapp.com :
  #   - otp.bin, seeprom.bin           -> Cemu's main folder
  #   - dumping_output/Online Files/mlc01/{sys,usr} -> Cemu's mlc01/
  # Then in Cemu: Options -> Graphics API -> Vulkan; Input settings ->
  # SDLController; right-click BOTW -> Edit graphics packs -> download
  # community packs -> enable FPS++.
}
