{ config, lib, pkgs, ... }:
# Button-driven scanning from the Fujitsu fi-7160 (duplex ADF) into paperless-ngx.
#
# Workflow: load a stack of paper, press the scanner's Scan button. scanbd (the
# scanner button daemon) detects the button press and runs the scan action, which
# pulls every sheet through the ADF in one batch, combines the pages into a single
# PDF, and atomically drops it into paperless's consume dir
# (/var/lib/paperless/consume) where paperless OCRs and files it.
#
# One button press == one document (the ADF "out of paper" signal ends the batch).
# Two documents -> two stacks -> two presses.
#
# fi-7160 uses the `fujitsu` SANE backend (included in sane-backends); unlike the
# ScanSnap/epjitsu models it needs no firmware upload. There is no NixOS module for
# scanbd, so the daemon + config are wired up by hand below (pattern from the NixOS
# wiki Scanners page, adapted from the upstream scanbd.conf example).
let
  # Default scan profile. Tweak these and `nixos-rebuild switch`.
  source  = "ADF Duplex";   # both sides; blank backs dropped by swskip below
  mode    = "Color";        # Color | Gray | Lineart
  res     = "300";          # dpi
  swskip  = "5";            # blank-page skip: drop pages with < N% content

  # Paper size of the scan window, in mm. Set to Legal (8.5 x 14") so both Letter
  # and Legal — and mixed stacks — are captured without clipping; --swcrop=yes
  # (below) then trims each page down to its real edges, so shorter sheets aren't
  # padded with blank space. For long-document mode (up to ~220") raise pageHeight
  # and drop res to <=200. fi-7160 max width is 8.5".
  pageWidth  = "215.9";     # 8.5 in
  pageHeight = "355.6";     # 14 in (Legal)

  consumeDir = "${config.services.paperless.dataDir}/consume";
  # Staging must share a filesystem with consumeDir so the final `mv` is an atomic
  # rename — paperless then only ever sees the complete PDF, never a partial write.
  staging    = config.services.paperless.dataDir;

  # The scan action. scanbd runs as root and exports $SCANBD_DEVICE (the SANE device
  # string for the scanner whose button fired); we target that exact device.
  scanScript = pkgs.writeShellApplication {
    name = "paperless-scan";
    runtimeInputs = with pkgs; [ sane-backends img2pdf coreutils ];
    text = ''
      device="''${SCANBD_DEVICE:-}"

      work="$(mktemp -d -p "${staging}" .scan.XXXXXX)"
      trap 'rm -rf "$work"' EXIT

      dev_args=()
      [ -n "$device" ] && dev_args=(--device-name="$device")

      # scanimage returns 7 (SANE_STATUS_NO_DOCS) at normal end-of-batch once the ADF
      # empties — after it has already written every scanned page. Treat 0 and 7 as success.
      rc=0
      scanimage "''${dev_args[@]}" \
        --source "${source}" --mode "${mode}" --resolution "${res}" \
        --page-width "${pageWidth}" --page-height "${pageHeight}" \
        --swcrop=yes --swdeskew=yes --swskip="${swskip}" \
        --batch="$work/p%04d.tif" --format=tiff || rc=$?
      if [ "$rc" -ne 0 ] && [ "$rc" -ne 7 ]; then
        echo "scanimage failed (rc=$rc)" >&2
        exit "$rc"
      fi

      shopt -s nullglob
      pages=("$work"/p*.tif)
      if [ "''${#pages[@]}" -eq 0 ]; then
        echo "no pages scanned (empty feeder?); nothing to consume" >&2
        exit 0
      fi

      img2pdf "''${pages[@]}" -o "$work/scan.pdf"

      dest="${consumeDir}/scan-$(date +%Y%m%d-%H%M%S)-$$.pdf"
      mv "$work/scan.pdf" "$dest"           # atomic rename within ${staging}
      chown paperless:paperless "$dest"
      chmod 0644 "$dest"
      echo "delivered $dest (''${#pages[@]} pages)"
    '';
  };
in {
  # SANE: registers the fujitsu backend and the udev rules that grant device access.
  hardware.sane.enable = true;

  # scanbd config. The daemon polls every attached scanner; when an option matching a
  # filter flips from from-value to to-value it runs the action's script. The fujitsu
  # backend exposes the Scan button as a "scan" sensor (1 -> 0 on press).
  environment.etc."scanbd/scanbd.conf".text = ''
    global {
      debug = true
      debug-level = 3          # 1=err 2=warn 3=info 4-7=debug; raise to 7 to debug buttons
      user = root
      group = root
      saned = ""               # manager mode unused; we scan only via the button
      scriptdir = /etc/scanbd/scripts
      timeout = 500            # device poll interval [ms]
      pidfile = "/run/scanbd.pid"
      environment {
        device = "SCANBD_DEVICE"
        action = "SCANBD_ACTION"
      }
      multiple_actions = true
      action scan {
        filter = "^scan.*"
        numerical-trigger {
          from-value = 1
          to-value   = 0
        }
        desc = "Scan ADF stack to paperless"
        script = "scan.script"
      }
    }
  '';
  environment.etc."scanbd/scripts/scan.script".source =
    "${scanScript}/bin/paperless-scan";

  systemd.services.scanbd = {
    description = "Scanner button polling daemon (fi-7160 -> paperless)";
    wantedBy = [ "multi-user.target" ];
    after = [ "paperless-consumer.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.scanbd}/bin/scanbd -f -c /etc/scanbd/scanbd.conf";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
