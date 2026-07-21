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
- sulphur: flameshot's `<Ctrl><Alt><Shift>s` binding failed with "Unable to capture
  screen" on GNOME Wayland. gsd-media-keys children inherit its `session.slice` cgroup,
  so xdg-desktop-portal attributed the Screenshot request to that unit rather than the
  empty host app-id holding the permission-store grant; the resulting permission dialog
  was refused by mutter because flameshot has no focus. `modules/dconf.nix` now launches
  it via `systemd-run --user`, placing it in `app.slice` where the grant applies.
  Depends on `~/.local/share/flatpak/db/screenshot`, which is not declarable — if wiped,
  run `flameshot gui` once from a focused terminal and approve the prompt.
- sulphur: flameshot's selection overlay only covered one monitor. A Wayland client
  cannot span one surface across outputs; `QT_QPA_PLATFORM=xcb` makes the overlay an
  X11 window over rootless Xwayland's full 4000x3040 root, covering all three displays.
  Capture still comes from the Screenshot portal, so image content is unaffected.

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
