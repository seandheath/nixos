{ config, pkgs, nixpkgs,  ... }:
{
  services.syncthing = {
    enable = true;
    user = "lo";
    dataDir = "/home/lo";
    configDir = "/home/lo/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
    devices = {
      osmium = { id="EBP6MYZ-HRSGNIM-NN2BHXA-5MUTIY4-SMVSURX-7UTNJJM-NITPVQW-OTBDRAP"; };
      hydrogen = { id="MYER4GQ-ZRIXY7J-WD7LZB2-ZZ2L4JM-OIV4OUQ-HEICL7U-6IMPDPY-HP3MGQT"; };
      pixel = { id = "CPSSA5L-J3PWVDU-53M3H4L-3ALJKMI-WXNEJEV-VM2PGIR-PNLJDUC-WQDRMQQ"; };
    };
  };
}
