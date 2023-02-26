{ config, pkgs, ... }: {
  # Enable NVIDIA driver
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };
  environment.systemPackages = with pkgs; [
    nvtop
  ];
}
