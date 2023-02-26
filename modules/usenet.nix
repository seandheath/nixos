{ config, nixpkgs, pkgs, lib, ... }:
let
  id = 2000;
in {
  users.groups.usenet.gid = id;
  users.users.usenet = {
    isSystemUser = true;
    uid = id;
    group = "usenet";
    extraGroups = [ "video" ];
  };
  networking.firewall.allowedTCPPorts = [ 6789 8096 7878 8989 ];
  services.nzbget = {
    enable = true;
    user = "usenet";
    group = "usenet";
  };
  services.sonarr = {
    enable = true;
    user = "usenet";
    group = "usenet";
  };
  services.radarr = {
    enable = true;
    user = "usenet";
    group = "usenet";
  };
  services.jellyfin = {
    enable = true;
    user = "usenet";
    group = "usenet";
  };
  nixpkgs.overlays = [
    (self: super: {
      my_ffmpeg = super.ffmpeg_5-full.overrideAttrs (old: {
        postFixup = ''
          addOpenGLRunpath ${placeholder "lib"}/lib/libavcodec.so
          addOpenGLRunpath ${placeholder "lib"}/lib/libavutil.so
        '';
      });
    })
  ];
  environment.systemPackages = with pkgs; [
    my_ffmpeg
  ];
}
