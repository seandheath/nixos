# System-wide sops-nix defaults. keyFile derives from the sheath user's home
# (config.users.users.sheath.home) rather than a hardcoded path, so the module
# is not username/home-locked.
{ config, ... }:
{
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "${config.users.users.sheath.home}/.config/sops/age/keys.txt";
  # The installer provisions the age key before activation.  Do not make fresh installs
  # probe host SSH keys that do not exist until OpenSSH is activated.
  sops.age.sshKeyPaths = [ ];
  sops.gnupg.sshKeyPaths = [ ];
}
