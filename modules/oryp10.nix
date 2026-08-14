# System76 Oryx Pro 10 (Intel iGPU + NVIDIA dGPU). Values verified on this machine when it
# ran as sheath's `osmium`; recovered from e560e78^. See CHANGELOG 2026-08-14.
{ pkgs, ... }:
{
  boot.kernelParams = [
    "pcie_aspm=off"          # Xid 79: the dGPU falls off the bus under ASPM
    "nvme_core.default_ps_max_latency_us=0"
    "iwlwifi.power_save=0"   # missed beacons
    "usbcore.autosuspend=-1" # xHCI resume
  ];
  boot.blacklistedKernelModules = [ "spd5118" "framebuffer_coreboot" ];
  boot.extraModprobeConfig = ''
    options nvidia NVreg_PreserveVideoMemoryAllocations=1
  '';

  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" "modesetting" ]; # offload needs modesetting
  };

  hardware = {
    enableRedistributableFirmware = true;
    system76.enableAll = true; # kernel modules, firmware daemon, power daemon
    nvidia = {
      open = false;
      nvidiaSettings = true;
      modesetting.enable = true;
      powerManagement.enable = true;
      # Both guard the same failure: this card drops off the bus when it is allowed to
      # power down, so keep it initialised and keep RTD3 off.
      nvidiaPersistenced = true;
      powerManagement.finegrained = false;
      prime = {
        offload.enable = true;
        offload.enableOffloadCmd = true;
        nvidiaBusId = "PCI:1:0:0";
        intelBusId = "PCI:0:2:0";
      };
    };
    graphics.extraPackages = with pkgs; [ intel-media-driver nvidia-vaapi-driver ];
  };

  services.system76-scheduler.enable = true;
  services.fstrim.enable = true;
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
  '';

  environment.systemPackages = with pkgs; [
    system76-firmware
    system76-keyboard-configurator
  ];
}
