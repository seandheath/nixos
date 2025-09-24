# This is a placeholder file for the hydrogen hardware configuration.
# The install.sh script will overwrite this with the generated hardware-configuration.nix.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  # The installer will generate the correct boot and filesystem settings.
}
