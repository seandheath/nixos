# Reusable Headscale-managed Tailscale client.  No NetworkManager profile or
# tailscaled owns tailscale0 and follows the host's changing uplinks itself.
{ config, lib, pkgs, ... }:
let
  cfg = config.fleet.tailscaleClient;
  tailscale = lib.getExe config.services.tailscale.package;
  desiredSetFlags = [
    "--accept-dns=${lib.boolToString cfg.acceptDns}"
    "--accept-routes=${lib.boolToString cfg.acceptRoutes}"
    # Never select an exit node: ordinary Internet traffic keeps using the
    # current Wi-Fi/Ethernet default route.
    "--exit-node="
  ];
  # A tagged Headscale pre-auth key assigns the node's tags. Headscale rejects
  # enrollment when that same request also advertises tags from the client.
  desiredUpFlags = desiredSetFlags;
in
{
  options.fleet.tailscaleClient = {
    enable = lib.mkEnableOption "the Headscale-managed Tailscale client";

    loginServer = lib.mkOption {
      type = lib.types.str;
      default = "https://headscale.luckyobserver.com";
      description = "Public Headscale URL used for initial enrollment.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional file containing a one-time Headscale pre-authentication key.
        Supply it with sops-nix; never put the key itself in Nix source.
        Leave null for interactive enrollment.
      '';
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tag:admin" ];
      description = ''
        Expected Headscale policy tags for this node. These document which
        tagged pre-auth key to use; the client does not request them itself.
      '';
    };

    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept approved subnet routes from the home router.";
    };

    acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept MagicDNS and Headscale's stable service records.";
    };

    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "TCP ports reachable on this machine through tailscale0.";
    };

    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "UDP ports reachable on this machine through tailscale0.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.hasPrefix "https://" cfg.loginServer;
      message = "fleet.tailscaleClient.loginServer must use public HTTPS.";
    }];

    services.tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = cfg.authKeyFile;
      useRoutingFeatures = "client";
      extraUpFlags = [ "--login-server=${cfg.loginServer}" ] ++ desiredUpFlags;
    };

    networking.firewall.interfaces.tailscale0 = {
      allowedTCPPorts = cfg.allowedTCPPorts;
      allowedUDPPorts = cfg.allowedUDPPorts;
    };

    # authKeyFile is consumed only when the daemon reports NeedsLogin.  This
    # non-periodic companion reapplies the non-secret preferences on rebuilds,
    # while tailscaled itself handles suspend/resume and network roaming.
    systemd.services.tailscale-configure = {
      description = "Reconcile declarative Tailscale preferences";
      after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.jq ];
      serviceConfig.Type = "oneshot";
      script = ''
        state="$(${tailscale} status --json --peers=false 2>/dev/null \
          | jq -r '.BackendState // empty' || true)"

        if [ "$state" = Running ]; then
          exec ${tailscale} set ${lib.escapeShellArgs desiredSetFlags}
        fi

        echo "tailscale is not enrolled (state: ''${state:-unknown}); leaving it running"
      '';
    };
  };
}
