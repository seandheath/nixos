# Changelog

## [Unreleased]
### Added
- hydrogen: self-hosted services — Nextcloud (`nc.nheath.com`), Immich
  (`immich.nheath.com`), calibre-web (`calibre.nheath.com`), paperless-ngx
  (`paper.nheath.com`), all reverse-proxied by nginx and reachable only over
  WireGuard/LAN. New modules: `modules/{nextcloud,immich,calibre,paperless}.nix`.
- hydrogen wired into `flake.nix` `nixosConfigurations` (was previously absent).
- `modules/reverse-proxy.nix`: wildcard `*.nheath.com` TLS via Cloudflare ACME DNS-01
  (`acme-dns-credentials` sops secret); per-service vhosts attach via `useACMEHost`.
- `docs/nixrouter-wireguard-handoff.md`: router-side instructions (WireGuard split-tunnel
  server + dnsmasq split-horizon DNS) for the separate `nixrouter` repo.

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
- Add sops secrets `acme-dns-credentials` (Cloudflare `CF_DNS_API_TOKEN`) and
  `paperless-adminpass`.
- Confirm `/data` is mounted to the real disk (placeholder UUID in `hosts/hydrogen.nix`).
- Initialise calibre library: `calibredb add --library-path /data/calibre-library --empty`.
