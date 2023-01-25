{ config, lib, ... }: {
  networking.hostName = "qemu-microvm";
  users.users.root.password = "";
  microvm.hypervisor = "qemu";
  microvm.forwardPorts = [{
    host.port = 9999;
    guest.port = 22;
  }];
  networking.firewall.alowedTCPPorts = [ 22 ];
  services.openssh = {
    enable = true;
    permitRootLogin = "yes";
  }
}