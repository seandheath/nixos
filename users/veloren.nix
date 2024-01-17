{ config, pkgs, ... }:{
  users.users.veloren = {
    extraGroups = [ "networkmanager" ];
    isNormalUser = true;
  };
}
