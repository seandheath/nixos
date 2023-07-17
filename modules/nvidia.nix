{ config, pkgs, ... }:{
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };
  hardware.nvidia = {
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;
    powerManagement.enable = true;
    forceFullCompositionPipeline = true;
  };
  services.xserver.videoDrivers = ["nvidia"];
}
