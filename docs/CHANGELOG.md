# Changelog

## [Unreleased]
### Added
- hydrogen: self-hosted services — Nextcloud (`nc.luckyobserver.com`), Immich
  (`immich.luckyobserver.com`), calibre-web (`calibre.luckyobserver.com`), paperless-ngx
  (`paper.luckyobserver.com`), reachable only over WireGuard/LAN. New modules:
  `modules/{nextcloud,immich,calibre,paperless}.nix`.
- hydrogen wired into `flake.nix` `nixosConfigurations` (was previously absent).
- `modules/reverse-proxy.nix`: **http-only** internal nginx on hydrogen (port 80, routes
  by Host). TLS is terminated on the router (which holds the Cloudflare token + wildcard
  cert); Nextcloud trusts the router via `trusted_proxies`/`overwritehost`. No ACME/cert
  on hydrogen.
- `docs/nixrouter-wireguard-handoff.md`: router-side instructions (WireGuard split-tunnel
  server, **nginx + `*.luckyobserver.com` Cloudflare DNS-01 wildcard TLS**, and
  dnsmasq split-horizon DNS pointing to the router `10.0.0.1`) for the separate
  `nixrouter` repo.

### Changed
- hydrogen: 25.11 compatibility fixes — removed deprecated `sound.enable`, renamed
  `hardware.opengl` → `hardware.graphics`, set required `hardware.nvidia.open = false`,
  dropped removed `thefuck` package.

### Added (impermanence install)
- `install.sh`: new mode 3 "Impermanence (Btrfs, no encryption)" for unattended remote
  reboot (no LUKS prompt); a `/data` disk prompt that mounts an existing partition by
  detecting its UUID + fstype via `blkid` (no reformat); and an optional sops age-key
  install step. All disk-dependent values are written into the generated
  `hardware/<host>.nix`.
- `modules/impermanence-server.nix`: layout-only Btrfs/`/persist` module for hydrogen
  (no LUKS, no active root-wipe; matches sulphur's real behaviour).

### Changed (impermanence install)
- `hosts/hydrogen.nix`: now imports the installer-generated `hardware/hydrogen.nix`
  (single source of disk UUIDs) + `impermanence-server.nix`; inline `fileSystems`/`boot`/
  `swapDevices`/`hostPlatform`/microcode removed; `networking.useDHCP = false` (plain).
- Service modules gate startup on the `/data` mount via `RequiresMountsFor = "/data"`.

### TODO (before switch)
- Add sops secret `paperless-adminpass` to this repo. (`acme-dns-credentials` now lives on
  the router, not hydrogen.)
- Router side (separate `nixrouter` repo): add nginx + ACME wildcard + WireGuard per
  `docs/nixrouter-wireguard-handoff.md`; point split-horizon DNS at the router.
- Confirm `/data` is mounted to the real disk (installer prompt / generated hardware file).
- Initialise calibre library: `calibredb add --library-path /data/calibre-library --empty`.
