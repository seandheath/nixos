{ config, ... }: {
  imports = [ "${builtins.fetchTarball "https://github.com/Mic92/sops-nix/archive/master.tar.gz"}/modules/sops" ];
  sops.defaultSopsFile = ../secrets/secrets.yaml;
  sops.age.keyFile = "/root/sops-key.txt";
  sops.age.generateKey = false;
}
