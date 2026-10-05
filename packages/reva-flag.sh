# Sourced by host and container launchers; preserve the upstream -- boundary.
reva=false
_kept=()
_wrapper_options=true
for _arg in "$@"; do
  if $_wrapper_options && [[ "$_arg" == --reva ]]; then
    reva=true
  else
    _kept+=("$_arg")
    if [[ "$_arg" == -- ]]; then _wrapper_options=false; fi
  fi
done
set -- "${_kept[@]}"
