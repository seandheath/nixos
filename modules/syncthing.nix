{ config, lib, ... }: {
  services.syncthing = {
    enable = true;
    openDefaultPorts = lib.mkDefault true;
    user = "sheath";
    dataDir = config.users.users.sheath.home;
    configDir = "${config.users.users.sheath.home}/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
  };
}
