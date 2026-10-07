# Hydrogen Git hosting

Forgejo is the private source of truth at `https://git.luckyobserver.com`.
Git SSH uses `ssh://git@git.luckyobserver.com:2222/sheath/<repo>.git` or
`hydrogen-forge:sheath/<repo>.git`. Administrative SSH stays on port 22.
The native NixOS module selects Forgejo LTS; `flake.lock` pins it and Runner.

## Deployment state and bootstrap

Forgejo was activated on Hydrogen on 2026-10-07. Legacy SSH writes are now disabled;
the old repository data remains for rollback. The initial administrator
password is generated and encrypted in `secrets/forgejo.yaml` for the existing
main SOPS recipient. No GitHub mirror or publishing credential is provisioned.
The runner is enrolled only for the private `sheath/forgejo-ci-checks` repository.
Other repositories require their own admission and registration.

Live checks passed: valid HTTPS with an explicit DNS override, login page 200,
unauthenticated repository search 403, tailnet-only SSH listener, administrator
creation and a mode-0600 backup export. `groundedgadgets` was copied to the private
`sheath/groundedgadgets` repository; a fresh mirror clone matched every ref and
passed `git fsck --full`. The personal SSH key is registered. A live runner job
passed with a SHA-pinned checkout action, exact-commit verification and checks for
absent host secrets/sockets. The off-site pre-migration archive is
`hydrogen-remote-2026-10-07T12:08:44`.

Headscale now serves `git.luckyobserver.com → 100.64.0.3`, but the client's OS resolver
still needs a split-DNS route for this name. `tailscale dns query` succeeds while
`resolvectl query` fails. A post-migration off-site backup/restore, client remote
updates, and migration API-token revocation remain pending. Deployment logs are
on Hydrogen in `/tmp/forgejo-deploy.ZTOCXxZg/`.

Database creation exposed pre-existing libc collation drift (2.42 → 2.44).
`template1` had no application tables; it was dumped to
`/var/backup/postgresql/forgejo-deploy/template1-before-reindex.dump`, reindexed
(database and system indexes), then its collation version was refreshed.
Concurrent reindexing and version refresh for `postgres`, `nextcloud` and `immich`
were started in `forgejo-collation-maintenance.service`; completion still needs
verification. Rebuild affected indexes before refreshing version metadata;
see [PostgreSQL's collation guidance](https://www.postgresql.org/docs/current/sql-altercollation.html).

1. Complete the split-DNS routing for the Headscale extra record
   (`modules/headscale-server.nix` in the router repository). The shared client name
   list and Hydrogen's own resolution are configured here. Keep port 2222 limited
   to administrative tailnet clients in Headscale policy; do not forward it on WAN.
2. Retrieve the initial password locally when needed with
   `sops --decrypt --extract '["forgejo-admin-password"]' secrets/forgejo.yaml`.
   Hydrogen already declares the SOPS secret and bootstrap input. The bootstrap
   unit creates `sheath` only if absent; it does not reset an existing password
   on rebuild. Keep the SOPS recovery key off the machine too.
3. Build with `nix build path:.#nixosConfigurations.hydrogen.config.system.build.toplevel`.
   Activate on Hydrogen using the normal fleet deployment procedure. Check
   `forgejo`, `forgejo-bootstrap`, nginx and PostgreSQL in `systemctl`/`journalctl`.
4. Log in as `sheath`, change the initial password if prompted, enable 2FA and
   add the personal public SSH key from `users/sheath.nix` through Forgejo's UI.
   Verify the SSH host fingerprint on Hydrogen before accepting it on clients.
5. Confirm HTTPS and authenticated clone/push from an administrative tailnet
   client. An unauthenticated request must not reveal private repository contents;
   HTTP port 3001 must only listen on loopback. Ports 443/2222 must be unreachable
   from the ordinary LAN/WAN. Family tailnet clients still need Forgejo credentials.

The wildcard ACME certificate, private nginx vhost, PostgreSQL peer authentication
and generated Forgejo keys use the existing NixOS facilities. All Forgejo state
is under `/var/lib/forgejo`; Hydrogen's root filesystem already persists reboot.
Signing keys stay offline. Application-generated encryption/SSH keys are persisted
and backed up; provisioned passwords and runner tokens use SOPS runtime files.

Local checks: `python3 tests/test_forgejo.py /path/to/pinned/nixpkgs` evaluates the
configuration and exercises export failure handling with disposable state.
`tests/forgejo-vm.nix` gives the command for the isolated integration test. Run that
test and the Hydrogen build on a machine with Nix daemon/KVM access before cutover.

Validated on Hydrogen on 2026-10-07: the full host build, runner-enabled build,
offline checks and VM integration test passed. The VM covers private SSH push/clone,
repository-scoped rootless CI with exact-commit checkout and no container-engine sockets or host secrets,
failed-export recovery, database/state restoration and another CI job after a VM
restart. Client DNS and off-site Borg recovery still require cutover checks.

## Pushing from developer containers

The updated `cclaude`, `ccodex` and `copencode` launchers forward a live
`SSH_AUTH_SOCK`. They mount only `~/.ssh/personal.pub` to select the registered
agent identity; private key files stay on the host. Forwarding permits use of
the keys loaded in that agent. Forgejo's host key is pinned in
`packages/forgejo-known-hosts`, and the launchers provide its tailnet IP inside
the containers. Qwen launchers do not receive the agent.

Load the key on the host before starting a new container:

```sh
ssh-add ~/.ssh/personal
ccodex                  # or copencode / cclaude
```

The host must have `~/.ssh/personal.pub` beside the key. If needed, generate only
the public half with `ssh-keygen -y -f ~/.ssh/personal > ~/.ssh/personal.pub`.
Inside the updated container, use an existing Forgejo repository:

```sh
git remote set-url origin ssh://git@git.luckyobserver.com:2222/sheath/groundedgadgets.git
git push -u origin HEAD
```

For a new repository, create it as private in Forgejo first, then use `git remote
add origin` with its owner/repository URL. Pushing to Forgejo does not publish to
GitHub. Public mirroring remains unconfigured.

For API access, SOPS decrypts `remote-coding` to `/run/secrets/remote-coding`,
readable only by the workstation user. Host Claude, Codex and OpenCode can read
it directly; their container launchers mount the same path read-only. After
rebuilding Sulfur, start new containers to receive the token. The shared agent
instructions identify the API URL and token file; never print the token.

The SSH-enabled launchers are installed. The API-token mounts need another
rebuild; live container authentication remains unverified because the agent
sandbox blocks sockets. Apply the changes on Sulfur from the user's normal
terminal, then start a new container:

```sh
sudo nixos-rebuild switch --flake path:/home/sheath/nixos#sulfur
hash -r
```

## Replace the bare Git service

Do not skip the write freeze or delete `/var/lib/git` during cutover.

1. Inventory `sudo git-repo list` and, for each bare repository, record
   `git symbolic-ref HEAD`, `git for-each-ref --format='%(refname) %(objectname)'`,
   custom hooks, and LFS data. Run `git fsck --full` as the `git` user. Run
   `sudo borg-cmd backup --remote` and verify its successful archive.
2. Create corresponding **private, empty** repositories under `sheath` in
   Forgejo. Leave Actions disabled during import. Match each original default
   branch; preserve empty repositories too.
3. Temporarily set `fleet.gitServer.authorizedKeys = [ ];` and deploy. This
   disables the old Git transport while administrative SSH remains available.
   Wait for any existing `git-receive-pack` sessions to finish. Copy each frozen
   repository through administrative SSH into a private temporary directory on
   the migration workstation, for example:

   ```sh
   umask 077
   migration_dir=$(mktemp -d)
   # Substitute one inventoried repository name for REPO in these commands.
   ssh hydrogen 'sudo -n tar -C /var/lib/git -cf - REPO.git' > "$migration_dir/source.tar"
   tar -xf "$migration_dir/source.tar" -C "$migration_dir"
   git clone --mirror --no-hardlinks "$migration_dir/REPO.git" "$migration_dir/import.git"
   git -C "$migration_dir/import.git" remote add forge hydrogen-forge:sheath/REPO.git
   git -C "$migration_dir/import.git" push --mirror forge
   ```

   `--mirror` here is only for the private migration into an empty repository.
   Never use it for GitHub publication. Inspect any unusual refs before import;
   stop on rejected refs rather than declaring a partial import successful.
   Transfer any inventoried LFS objects with Git LFS, then `git lfs push --all forge`.
   An object missing from the old server must be recovered from a complete clone.
4. Compare every ref ID with a fresh Forgejo mirror clone and run `git fsck`.
   Check the default branch and fetch all LFS objects. Register any still-needed
   hook behavior deliberately; do not copy old hooks over Forgejo's generated hooks.
   Verify authenticated push/fetch and an off-site backup/isolated restore below.
5. Update client remotes to the owner-prefixed Forgejo URLs. Then remove the old
   Git module import and `fleet.gitServer` declarations from Hydrogen and retire
   `modules/git-server.nix`. Point `hydrogen-git` at the same host/port as
   `hydrogen-forge`, documenting that paths now include `sheath/`. Keep the
   `/var/lib/git` backup entry and non-serving data through rollback verification.

Before new work lands in Forgejo, rollback can restore the original authorized
keys and old URLs. After new pushes, first reconcile all new Forgejo refs and LFS
objects back into the old repositories under another write freeze. Never roll
back to the frozen copy and silently discard new commits. A NixOS generation
rollback alone does not roll back a migrated Forgejo database.

## Runner enrollment and verification

Enable Actions only for admitted repositories. For each, create a
**repository-scoped** runner in its Settings → Actions → Runners page; copy its
UUID and store its token as a separate SOPS secret. One runner process handles
these registrations with capacity one:

```nix
sops.secrets.forgejo-runner-protocol.restartUnits = [ "forgejo-runner-hydrogen.service" ];
fleet.forgejo.runnerConnections.hestia-protocol = {
  uuid = "<UUID from the repository runner registration>";
  tokenFile = config.sops.secrets.forgejo-runner-protocol.path;
};
```

The `forgejo-ci` account (UID 1102) has no SSH keys or sudo privileges. Its Podman
API socket is private to that account. The runner gets the socket through
`DOCKER_HOST`, but jobs do not get that socket or `/run/secrets`. Jobs mount the
host `/nix/store` and Nix daemon socket directory read-only; the daemon accepts
build requests as the untrusted `forgejo-ci` user. The runner is not a Nix
trusted user and cannot change the daemon's trust or sandbox policy.
Its image is built from the pinned Nixpkgs closure, loaded locally, and addressed
by a content-derived tag. `runs-on: hydrogen-linux` provides shell, Git, Node,
curl, Nix with flakes enabled, and basic CLI tools, **not an Ubuntu installation**.
Use each repository's `flake.lock` with `nix develop`, `nix build` or `nix flake
check` for pinned toolchains. Hydrogen provides aarch64 emulation for native
ARM builds. Downloads and builds populate the shared host store; existing paths
are reused until garbage collection removes them. Daemon builds use host Nix
resource limits, not the job container's CPU and memory limits. Tools running
directly inside jobs still have no hardware devices or KVM access.

After enrollment, run a disposable private repository workflow that checks out
its exact commit with a SHA-pinned checkout action, prints tool versions, and
asserts Docker/Podman sockets and `/run/secrets` are absent. Check that the Nix
daemon socket is present and run a small `nix build`; verify its output is readable
and direct store writes are rejected.
Try an unauthorized bind mount and confirm rejection. Verify fresh workspaces,
container cleanup, successful jobs after a runner restart and a host reboot.
Admit only trusted workflow authors: rootless containers reduce host access;
they do not make arbitrary workflows safe to run with publishing credentials.
The Forgejo Actions cache service is disabled. Logs are in `journalctl -u forgejo-runner-hydrogen`
and `journalctl -u forgejo-podman`.

## Backup and recovery

`borg-cmd backup` first awaits `forgejo-backup.service`. The export stops Forgejo,
takes a native PostgreSQL custom-format dump, and archives **all** Forgejo state,
including Actions artifacts, attachments, LFS and generated encryption keys.
It atomically replaces `/var/backup/forgejo/forgejo.tar`. ExecStopPost restarts
Forgejo even if export fails or is terminated; Borg aborts on an export failure.
The old completed export remains intact. Jobs uploading during the brief outage
may need rerunning. Borg then backs up the export to both local disks and BorgBase.
Use `borg-cmd backup`, not individual Borg job units, to obtain a fresh export.

The export contains `state/`, `database.dump`, and `VERSION`. Runner caches and
container storage are disposable; registration UUIDs live in configuration and
tokens in SOPS. Preserve the Nix configuration, encrypted SOPS files and a separate
copy of their decryption key. Backup failures are visible as failed systemd units;
check both `forgejo-backup` and `fleet-borg-backup` after deployment.

Restore into an isolated machine first, with the same Forgejo and PostgreSQL major
versions. Disable runners and outbound integrations; do not give the test machine
Hydrogen's production tailnet identity. Extract a Borg export to a root-only
directory and check `VERSION`, then:

1. Stop Forgejo. Restore `state/` into `/var/lib/forgejo`, owned by `forgejo:forgejo`.
2. In that disposable instance only, recreate the `forgejo` database with owner
   `forgejo`, then run `pg_restore --exit-on-error --no-owner --dbname=forgejo`
   as the `forgejo` OS user with `database.dump` on standard input.
3. Start Forgejo. NixOS regenerates hooks and runtime configuration. Verify login,
   SSH host identity, refs, LFS downloads, attachments, and an encrypted stored
   secret. Re-enroll runners only after successful recovery checks.

Test export failure by overriding the export unit's `FORGEJO_STATE` to a nonexistent
path in the isolated instance: the unit and Borg invocation must fail, Forgejo must
restart, and the previous export's hash must remain unchanged. Restore the correct
path and verify the next backup succeeds. A database downgrade requires a matching
pre-upgrade backup, not just the older NixOS generation.

## Hestia handoff (separate workspace change)

- Forgejo holds nine workspace repositories; owner-managed `hestia-ops` makes ten.
  Workspace, ops and site remain private permanently. The other seven are public
  **only at launch**: protocol, daemon, firmware, lists, app, cloud and testlab.
- Update plan §§3, 6.3, 6.4, 7 and the P0 prerequisites. Add Hosting to the repository
  table, private-site deployment to Cloudflare Pages, required secret scanning,
  and home CI → offline signing → GitHub Releases. Bootstrap uses a configurable
  forge base URL; update pinned dependency URLs and local overrides together.
- Convert CI to `.forgejo/workflows` and `hydrogen-linux`/appropriate toolchain
  labels. Similar YAML syntax does not guarantee action/toolchain compatibility.
- Until launch, use private test destinations and keep production publishing
  disabled. Gate the exact `main` SHA and individually selected release tags on
  builds, tests, license checks and scanning **all history newly exposed** by
  those refs. Tags must point to vetted public history. Fail closed on missing
  gates or divergence; no force pushes, `--mirror`, or blanket `--tags` pushes.
- Keep ordinary branch jobs separate from trusted publication workflows. An `if:`
  in a branch-editable workflow is not a credential boundary. Repository-scoped
  publish keys belong only to the trusted publisher, never arbitrary branch CI.
- At launch create seven empty public GitHub repositories and one write deploy
  key each. Use rulesets restricting updates with deploy-key bypass; keep deletion
  and force-push restrictions in separate rulesets without bypass. Only the one
  designated write key may be installed, since the bypass applies to the class.
- Enable GitHub issues, disable PRs in Settings → Features (no auto-close bot),
  keep CONTRIBUTING.md, point descriptions to the site and source links to GitHub.
  [GitHub PR settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/disabling-pull-requests).
- Build firmware/lists at home, transfer for offline signing, verify returned
  signatures and digests, then push the approved tag and publish signed assets.
  SSH deploy keys cannot upload release assets: use a separate repository-scoped
  API credential with Contents write permission. Routers fetch from GitHub.
  [GitHub release API](https://docs.github.com/en/rest/releases/releases).
- Cloudflare Workers and the private Pages site deploy from home CI using scoped
  Cloudflare tokens. App-store credentials stay in home CI; signing keys stay offline.
