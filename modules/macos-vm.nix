{ config, pkgs, ... }:
let
  macosVm = pkgs.writeShellScriptBin "macos-vm" ''
    set -euo pipefail
    cd "$HOME/vms/macos"
    conf=macos-tahoe.conf
    # Hand a connected iPhone or iPad to the VM.
    sed -i '/^usb_devices=/d' "$conf"
    if line=$(${pkgs.usbutils}/bin/lsusb -d 05ac: | grep -E 'iPhone|iPad' | head -n 1); then
      echo "usb_devices=(\"$(echo "$line" | awk '{print $6}')\")" >> "$conf"
    fi
    # Keep the VM off the two low-power cores (CPUs 14-15).
    exec ${pkgs.util-linux}/bin/taskset -c 0-13 \
      ${pkgs.quickemu}/bin/quickemu --vm "$conf" --ssh-port 22220 "$@"
  '';
  # setsid: QEMU must outlive the terminal that launched it.
  macosVmHeadless = pkgs.writeShellScriptBin "macos-vm-headless" ''
    exec ${pkgs.util-linux}/bin/setsid -w ${macosVm}/bin/macos-vm --display none "$@"
  '';
  # ACPI power-down so macOS shuts down cleanly; quickemu --kill is SIGKILL.
  macosVmStop = pkgs.writeShellScriptBin "macos-vm-stop" ''
    set -euo pipefail
    cd "$HOME/vms/macos"
    pid=$(< macos-tahoe/macos-tahoe.pid)
    echo system_powerdown | ${pkgs.socat}/bin/socat - unix-connect:macos-tahoe/macos-tahoe-monitor.socket
    ${pkgs.coreutils}/bin/tail --pid="$pid" -f /dev/null
  '';
in {
  users.groups.kvm.members = [ config.fleet.adminUser ];
  # macOS guests touch MSRs that KVM would otherwise reject.
  boot.extraModprobeConfig = "options kvm ignore_msrs=1 report_ignored_msrs=0";
  # Lets the VM take an iPhone/iPad without sudo.
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", MODE="0660", GROUP="kvm"
  '';
  environment.systemPackages = [ macosVm macosVmHeadless macosVmStop ];
}
