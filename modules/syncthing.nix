{ config, ... }: {
  services.syncthing = {
    enable = true;
    user = "luckyobserver";
    dataDir = "/home/luckyobserver";
    configDir = "/home/luckyobserver/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
    devices = {
      osmium = { id = "FLC6W4V-44AIZ5V-P63BUCM-76LLJVO-U6FVNZZ-5NRDH4O-CULNI5Z-3KRCZQL"; };
      hydrogen = { id = "MYER4GQ-ZRIXY7J-WD7LZB2-ZZ2L4JM-OIV4OUQ-HEICL7U-6IMPDPY-HP3MGQT"; };
      pixel = { id = "CPSSA5L-J3PWVDU-53M3H4L-3ALJKMI-WXNEJEV-VM2PGIR-PNLJDUC-WQDRMQQ"; };
      oxygen = { id = "6U7GYZN-YJ7WMWZ-2TGEBHV-57KNAGM-BDTNWN3-VHXZYMK-P2M4YH2-C5KB6QU"; };
    };
    openDefaultPorts = true;
  };
}
