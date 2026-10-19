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
  # Shut down over SSH: macOS ignores the ACPI power button (system_powerdown) when headless,
  # and quickemu --kill is SIGKILL.
  macosVmStop = pkgs.writeShellScriptBin "macos-vm-stop" ''
    set -euo pipefail
    pid=$(< "$HOME/vms/macos/macos-tahoe/macos-tahoe.pid")
    ssh -p 22220 dev@localhost sudo shutdown -h now
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
