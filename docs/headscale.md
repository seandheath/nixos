# Headscale/Tailscale home network

## Architecture

- `headscale.luckyobserver.com` is the public control endpoint.  nginx on the
  router terminates HTTPS and proxies to Headscale on loopback.
- Headscale stores SQLite, Noise keys, and policy state in
  `/var/lib/headscale`; the router's impermanence configuration persists it.
- tailscaled on the router advertises only `10.0.0.0/24`, with SNAT enabled.
  It does not advertise `0.0.0.0/0`, `::/0`, or the isolated VLANs.
- NixOS clients accept the LAN route and MagicDNS, but explicitly clear any
  exit-node selection.  Their ordinary Internet default route remains local.
- Standard Tailscale DERP servers remain enabled as fallback; no private DERP
  service is exposed.

The policy auto-approves `10.0.0.0/24` only for `tag:subnet-router`.
Untagged personal devices and `tag:admin` have general tailnet/LAN access.
`tag:family` has access only to the declared home service ports.

## Initial server deployment

1. In public DNS, create a DNS-only A record for
   `headscale.luckyobserver.com`. ddclient keeps it synchronized with the
   router's changing WAN IP.
2. Forward no new ports to an internal host.  The router itself accepts TCP 80
   (ACME HTTP-01 and HTTPS redirect), TCP 443 (Headscale), and Tailscale's UDP
   transport on its WAN interface.
3. Deploy `~/workspace/nixrouter`, then verify:

   ```console
   systemctl status headscale nginx tailscaled
   curl -fsS https://headscale.luckyobserver.com/health
   sudo headscale users list
   ```

The `home` Headscale user is created idempotently by
`headscale-bootstrap-owner.service`.

## One-time unattended enrollment

Create a separate default one-use, one-hour key for each machine.  A tagged
key is narrowly scoped to the machine role and becomes unusable after its
first successful enrollment:

```console
sudo headscale preauthkeys create --tags tag:subnet-router
sudo headscale preauthkeys create --tags tag:server
sudo headscale preauthkeys create --tags tag:admin
sudo headscale preauthkeys create --tags tag:family
```

Create one `tag:family` key per family laptop; never share a reusable key.
The tagged key assigns the tag; do not also pass `--advertise-tags` to
`tailscale up`, because Headscale rejects that combination.
Put each value in the target repository's existing sops file, for example
`tailscale-auth-router`, `tailscale-auth-hydrogen`, or
`tailscale-auth-gentlemenpupil`.  Then connect the decrypted path to the role:

```nix
sops.secrets.tailscale-auth-hydrogen = { };
fleet.tailscaleClient.authKeyFile =
  config.sops.secrets.tailscale-auth-hydrogen.path;
```

The router uses its own `secrets/secrets.yaml`; hydrogen and sulfur use this
repository's `secrets/secrets.yaml`; family laptops use
`secrets/family.yaml`.  Commit only the sops ciphertext.  After enrollment,
remove the consumed auth-key declaration on a later rebuild if desired.
`/var/lib/tailscale` contains the durable machine identity, so the key is not
needed again for rebuilds or reboots.

For an interactive personal device, enroll it under `home` without a tag:

```console
sudo tailscale up \
  --login-server=https://headscale.luckyobserver.com \
  --accept-routes=true \
  --accept-dns=true
```

Approve the printed registration request with the Headscale CLI.  The NixOS
module reapplies `--accept-routes=true` and `--exit-node=` after rebuilds.

## Validation

Run these checks from outside the home network:

1. `tailscale status` is `Running` after enrollment, reboot, suspend/resume,
   and switching Wi-Fi networks.
2. `tailscale ping router` succeeds.  Use `tailscale ping --until-direct` to
   observe a direct path when NAT permits it, then test on a restrictive
   network where the status shows a DERP relay.
3. `ip route get 10.0.0.10` uses `tailscale0`; SSH to `10.0.0.1` and
   `10.0.0.10` works as allowed by policy.
4. `nc.luckyobserver.com`, `immich.luckyobserver.com`,
   `paper.luckyobserver.com`, `calibre.luckyobserver.com`, and
   `mc.luckyobserver.com` resolve to `10.0.0.10` and work through the subnet
   route. `marketplace.luckyobserver.com` resolves to hydrogen's direct tail
   address so the Headscale admin policy can distinguish it from family access.
5. `ip route get 1.1.1.1` still names the current Wi-Fi/Ethernet interface,
   not `tailscale0`, and an external IP check shows the remote network's public
   address rather than the house.
6. `sudo headscale nodes list-routes` shows `10.0.0.0/24` as available,
   approved, and serving, with no default routes.
7. Rebuild router and client.  Neither asks for enrollment again, and no auth
   key appears in `git grep` or the Nix store.

The old fleet tunnels have been retired. `/var/lib/tailscale` is the durable
identity that must remain persisted on machines with ephemeral roots.
