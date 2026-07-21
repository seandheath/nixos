# Changelog

## [Unreleased]
### Added
- hydrogen: self-hosted services — Nextcloud (`nc.luckyobserver.com`), Immich
  (`immich.luckyobserver.com`), calibre-web (`calibre.luckyobserver.com`), paperless-ngx
  (`paper.luckyobserver.com`), all reverse-proxied by nginx and reachable only over
  WireGuard/LAN. New modules: `modules/{nextcloud,immich,calibre,paperless}.nix`.
- hydrogen wired into `flake.nix` `nixosConfigurations` (was previously absent).
- `modules/reverse-proxy.nix`: wildcard `*.luckyobserver.com` TLS via Cloudflare ACME DNS-01
  (`acme-dns-credentials` sops secret); per-service vhosts attach via `useACMEHost`.

### Changed
- hydrogen: 25.11 compatibility fixes — removed deprecated `sound.enable`, renamed
  `hardware.opengl` → `hardware.graphics`, set required `hardware.nvidia.open = false`,
  dropped removed `thefuck` package.

### Fixed
- sulphur: dropped flameshot entirely; `<Ctrl><Alt><Shift>s` now uses gnome-shell's
  built-in `area-screenshot-clip` (area select to clipboard, no portal round-trip).
  Flameshot on GNOME Wayland needed three stacked workarounds -- `systemd-run` for
  portal app-id attribution, `QT_QPA_PLATFORM=xcb` for a multi-monitor overlay, and
  `QT_FONT_DPI=96` for the overlay origin under 1.25 scaling -- and still discarded
  the selection, saving the full 4000x3040 desktop instead of the crop. Not worth
  carrying; the shell's built-in has none of these failure modes.
- sulphur: `home-manager.backupFileExtension = "hm-bak"` — a single unmanaged file HM
  wanted to own previously failed the whole activation and with it `nixos-rebuild switch`.

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
