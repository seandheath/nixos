# Called by gitea-backup.service; its ExecStopPost restores the service on failure.
set -euo pipefail
: "${GITEA_STATE:?}" "${GITEA_BACKUP:?}" "${GITEA_VERSION:?}" "${RUNTIME_DIRECTORY:?}"
umask 077

# Do not silently archive a failed or intentionally stopped forge as a healthy backup.
systemctl is-active --quiet gitea.service
touch "$RUNTIME_DIRECTORY/restart"
systemctl stop gitea.service

staging=$(mktemp -d "$GITEA_BACKUP/.partial.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
runuser -u gitea -- pg_dump --format=custom gitea > "$staging/database.dump"
printf '%s\n' "$GITEA_VERSION" > "$staging/VERSION"
# Prefix archive members/hardlinks, but preserve symlink targets exactly for restore.
tar -cf "$staging/export.tar" --transform='flags=rh;s,^,state/,' -C "$GITEA_STATE" .
tar -rf "$staging/export.tar" -C "$staging" database.dump VERSION
# A failed dump/archive leaves yesterday's export intact but fails today's Borg run.
mv -f "$staging/export.tar" "$GITEA_BACKUP/gitea.tar"
