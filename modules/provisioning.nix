# Marks hosts whose generated hardware and disk layout are local install artifacts.
{ lib, ... }:

{
  options.fleet.provisioning.enable = lib.mkEnableOption
    "machine-local hardware and disk provisioning state";

  options.fleet.hardware.isPlaceholder = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = "Whether this configuration still uses generated placeholder hardware.";
  };
}
