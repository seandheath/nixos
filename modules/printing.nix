# CUPS printing + SANE USB scanning. Extracted from workstation.nix.
{ pkgs, ... }:
{
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.epson-escpr2 pkgs.brlaser ];

  # USB scanning via SANE.
  # brscan4 covers the Brother MFC-L2707DW; USB devices are plug-and-play
  # (no brscan4_etc_files network registration needed).
  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.brscan4 ];
  };
  # brscan4's libsane-brother4.so has hardcoded absolute paths to
  # /etc/opt/brother/scanner/brscan4/{Brsane4.ini,models4/,brsanenetdevice4.cfg}.
  # nixpkgs ships an LD_PRELOAD wrapper that rewrites those paths into the store,
  # but only attaches it to the brsaneconfig4 CLI -- not to the .so loaded by
  # simple-scan/scanimage. Without this symlink any SANE client aborts in
  # modelinf.c (bugchk_free).
  systemd.tmpfiles.rules = [
    "L+ /etc/opt/brother - - - - ${pkgs.brscan4}/opt/brother"
  ];
}
