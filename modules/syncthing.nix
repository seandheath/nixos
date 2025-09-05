{ config, ... }: {
  services.syncthing = {
    enable = true;
    openDefaultPorts = true;
    user = "sheath";
    dataDir = "/home/sheath";
    configDir = "/home/sheath/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
  };
}
