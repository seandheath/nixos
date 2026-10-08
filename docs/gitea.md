# Hydrogen Git hosting

Gitea serves `https://git.luckyobserver.com` privately over the tailnet.
Git SSH uses port 2222 and user `git`; administrative SSH stays on port 22.
Registration is disabled and repositories are private by default.

## Fresh installation

Gitea was freshly installed on 2026-10-08 with an empty database and state
at `/var/lib/gitea`. Existing repositories, organizations, accounts, tokens, and
runner registrations are not imported. The `sheath` administrator is created once
from `secrets/gitea.yaml`; decrypt its `gitea-admin-password` key with SOPS to log in.
Change the initial password and register your SSH key in Gitea.

Hydrogen enables its Actions runner using the `gitea-actions-runner` secret in
`secrets/secrets.yaml`, which must contain `TOKEN=<registration token>`.
The runner uses `hydrogen-linux`
with rootless Podman, a read-only Nix store, and the untrusted Nix daemon socket.
Workflows belong in `.gitea/workflows/`.

The existing `ci-logs` SSH account reads completed Actions logs using
`ssh ci-logs@hydrogen 'owner/repo TASK_ID'`.

## Backup and restore

Borg waits for `gitea-backup.service`, which stops Gitea, exports PostgreSQL and
all application state to `/var/backup/gitea/gitea.tar`, and restarts Gitea even
when export fails. Shared historical Borg archives are not erased by the reset.
Legacy bare repositories under `/var/lib/git` are separate and remain untouched.

To restore into a disposable instance, stop Gitea, extract the archive, restore
`state/` to `/var/lib/gitea` owned by `gitea:gitea`, recreate database `gitea`
owned by `gitea`, and run `pg_restore --exit-on-error --no-owner --dbname=gitea`
as that OS user with `database.dump` on stdin. Start Gitea and verify clone/push.

## Checks and deployment

Run `python3 tests/test_gitea.py /path/to/pinned/nixpkgs`; the VM build command
is at the top of `tests/gitea-vm.nix`. Build Hydrogen with
`nix build path:.#nixosConfigurations.hydrogen.config.system.build.toplevel`.
Activate with `sudo nixos-rebuild switch --flake path:/home/sheath/nixos#hydrogen`.
The `path:` prefix includes the ignored `provisioning/hydrogen/` hardware files.
Check Gitea, bootstrap, nginx, PostgreSQL, HTTPS, SSH, and backup export afterward.

Hydrogen automatic upgrades are paused until this configuration is published to
GitHub `main`; then remove the `systemd.timers.nixos-upgrade.enable` override in
`hosts/hydrogen.nix`. The fresh SSH host key is pinned in
`packages/gitea-known-hosts`; update any previously trusted client key too.
