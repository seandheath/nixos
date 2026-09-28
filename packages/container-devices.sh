# Sourced by the agent container launchers (cclaude, ccodex, copencode). Removes
# --allow-usb / --allow-uart from "$@" and fills device_args with the podman flags that
# expose the host USB bus / serial ports. Host access is granted by udev (uaccess ACLs,
# dialout group) and carried in by --userns=keep-id plus keep-groups.
allow_usb=false
allow_uart=false
_kept=()
for _arg in "$@"; do
  case "$_arg" in
    --allow-usb) allow_usb=true ;;
    --allow-uart) allow_uart=true ;;
    *) _kept+=("$_arg") ;;
  esac
done
set -- "${_kept[@]}"

device_args=()
if $allow_usb; then
  if [[ ! -d /dev/bus/usb ]]; then
    printf '%s: --allow-usb requested, but /dev/bus/usb is unavailable\n' "${0##*/}" >&2
    exit 1
  fi
  # Bind the bus directory so devices that reconnect or re-enumerate remain visible.
  device_args+=(-v /dev/bus/usb:/dev/bus/usb:rw)
fi
if $allow_uart; then
  for _dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -c "$_dev" ]] && device_args+=(--device "$_dev:$_dev:rw")
  done
fi
if $allow_usb || $allow_uart; then
  device_args+=(--group-add=keep-groups)
fi
