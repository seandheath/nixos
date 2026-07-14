# Shared Bluetooth configuration. Imported by workstation.nix and
# surface-tablet.nix (deduplicated when a host pulls in both).
{ ... }:
{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings.General = {
      Enable = "Source,Sink,Media,Socket";
      Experimental = true; # battery reporting + better codec support
    };
  };
}
