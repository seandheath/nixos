{ config, pkgs, ... }: {
  services.trilium-server = {
    enable = true;
    host = "0.0.0.0";
  };
}
