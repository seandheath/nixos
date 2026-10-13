# Sourced by the agent container launchers (cclaude, ccodex). Removes --ynab from "$@",
# sets enable_ynab, and fills ynab_args with the read-only token mount.
enable_ynab=false
_kept=()
for _arg in "$@"; do
  if [[ "$_arg" == --ynab ]]; then
    enable_ynab=true
  else
    _kept+=("$_arg")
  fi
done
set -- "${_kept[@]}"

ynab_args=()
if $enable_ynab; then
  if [[ ! -s /run/secrets/ynab-api-token ]]; then
    printf '%s: --ynab requested, but /run/secrets/ynab-api-token is unavailable or empty\n' "${0##*/}" >&2
    exit 1
  fi
  ynab_args=(-v /run/secrets/ynab-api-token:/run/secrets/ynab-api-token:ro)
fi
