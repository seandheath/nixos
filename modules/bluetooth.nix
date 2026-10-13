# Shared Bluetooth configuration.
{ ... }:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General = {
      Experimental = true; # battery reporting + better codec support
    };
  };
}
