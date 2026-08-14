# CUPS printing + SANE USB scanning. Extracted from workstation.nix.
{ pkgs, ... }:
{
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.epson-escpr2 pkgs.brlaser ];

  # USB scanning via SANE.
  # brscan4 covers the Brother MFC-L2707DW; USB devices are plug-and-play
  # (no brscan4_etc_files network registration needed).
  hardware.sane.enable = true;
  # brscan4's libsane-brother4.so has hardcoded /etc/opt/brother paths; this module writes
  # that tree. nixpkgs' LD_PRELOAD wrapper only covers the brsaneconfig4 CLI, not the .so
  # that simple-scan and scanimage load.
  hardware.sane.brscan4.enable = true;
}
