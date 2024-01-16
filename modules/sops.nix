{ config, ... }: {
  imports = [
    <sops-nix/modules/sops>
  ];
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/root/sops-key.txt";
  sops.age.generateKey = false;
}
