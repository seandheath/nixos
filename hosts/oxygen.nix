# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      /etc/nixos/hardware-configuration.nix
    ];

  networking.hostName = "oxygen"; # Define your hostname.
  networking = {
    bridges = {
      "br0" = {
        interfaces = [ "enp4s0" ];
      };
    };
    interfaces = {
      enp4s0.mtu = 9000;
      br0 = {
        useDHCP = false;
	ipv4.addresses = [{
	  address = "10.0.0.10";
	  prefixLength = 24;
	}];
	mtu = 9000;
      };
    };
    defaultGateway = "10.0.0.1";
    nameservers = [ "10.0.0.1" ];
    firewall = {
      enable = true;
    };
  };
  virtualisation.libvirtd.allowedBridges = [ "br0" ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "22.11"; # Did you read the comment?

}

