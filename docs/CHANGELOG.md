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

### Added
- hydrogen: local LLM document classification for paperless. `modules/ollama.nix` runs
  ollama on loopback (`127.0.0.1:11434`, no vhost/firewall port) serving `qwen2.5:7b`;
  `modules/paperless-gpt.nix` runs `icereed/paperless-gpt` v0.27.0 as a pinned podman
  container (hydrogen's first container host) that watches paperless for the
  `paperless-gpt-auto` tag and writes back an LLM title/tags/correspondent/document-type.
  The container uses host networking to reach paperless and ollama on loopback; its own UI
  is bound to `127.0.0.1:8080`. API token in sops (`paperless-gpt-token`); `CREATE_NEW_TAGS`
  starts `false` so the model can only assign existing tags. `/var/lib/paperless-gpt` added
  to borg. NB: the P4200 is Pascal (sm_61), which is a non-default CUDA 12.8 gencode target,
  so `nixpkgs.config.cudaCapabilities = [ "6.1" ]` forces a from-source `ollama-cuda` build
  -- without it ollama silently ran on CPU (`total_vram="0 B"`). GPU inference measured at
  ~33 tok/s. This means every future nixpkgs ollama bump recompiles from source (~10 min).

### Fixed
- hydrogen: `modules/impermanence-server.nix` marks `/persist` `neededForBoot`, so sops
  secrets install at boot. `sops-install-secrets` runs from the initrd activation script,
  which executes before the ordinary fileSystems are mounted -- activation ran at 14:42:35
  and `/persist` was mounted at 14:42:38, so the age key at `/persist/secrets/age-keys.txt`
  was unreadable, `setupSecrets` failed, `/run/secrets` was never created, and every
  sops-consuming unit died with `243/CREDENTIALS`: paperless-{web,consumer,scheduler},
  `nextcloud-setup`, `acme-order-renew-luckyobserver.com`, and both borg jobs. The failure
  was self-concealing -- any later `nixos-rebuild switch` re-runs activation with `/persist`
  mounted and silently repairs `/run/secrets` -- so it was only visible between a reboot and
  the next rebuild, and had been failing on every boot since at least Jul 15. Verify this one
  across an actual reboot, not a rebuild.

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
