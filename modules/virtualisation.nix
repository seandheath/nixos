{ config, pkgs, lib, ... }:{
  programs.virt-manager.enable = true;
  users.groups.libvirtd.members = ["sheath"];
  users.groups.docker.members = ["sheath"];
  virtualisation.libvirtd.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;
  virtualisation.docker = {
    enable = true;
    autoPrune.enable = true;
    rootless = {
      enable = false;
      setSocketVariable = false;
    };
  };
  environment.systemPackages = with pkgs; [
    dive 
    docker-compose
  ];
}
