# Called by forgejo-backup.service; its ExecStopPost restores the service on failure.
set -euo pipefail
: "${FORGEJO_STATE:?}" "${FORGEJO_BACKUP:?}" "${FORGEJO_VERSION:?}" "${RUNTIME_DIRECTORY:?}"
umask 077

# Do not silently archive a failed or intentionally stopped forge as a healthy backup.
systemctl is-active --quiet forgejo.service
touch "$RUNTIME_DIRECTORY/restart"
systemctl stop forgejo.service

staging=$(mktemp -d "$FORGEJO_BACKUP/.partial.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
runuser -u forgejo -- pg_dump --format=custom forgejo > "$staging/database.dump"
printf '%s\n' "$FORGEJO_VERSION" > "$staging/VERSION"
# Prefix archive members/hardlinks, but preserve symlink targets exactly for restore.
tar -cf "$staging/export.tar" --transform='flags=rh;s,^,state/,' -C "$FORGEJO_STATE" .
tar -rf "$staging/export.tar" -C "$staging" database.dump VERSION
# A failed dump/archive leaves yesterday's export intact but fails today's Borg run.
mv -f "$staging/export.tar" "$FORGEJO_BACKUP/forgejo.tar"
