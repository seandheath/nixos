{ pkgs }:

# Runtime image for `ccodex` (see modules/codex-container.nix). Codex runs with its own
# sandbox disabled, so Podman is the security boundary: only the current project, the host
# Codex directory, and a dedicated home volume are writable. The host Nix store is mounted
# over the image's store at runtime so `nix develop` and `nix build` can use the host daemon,
# just as in cclaude.
let
  homeDir = "/home/codex";
  uid = 1000;

  passwdEtc = pkgs.runCommand "codex-container-etc" { } ''
    mkdir -p $out/etc/nix
    echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
    echo "codex:x:${toString uid}:${toString uid}:Codex:${homeDir}:/bin/bash" >> $out/etc/passwd
    echo "root:x:0:" > $out/etc/group
    echo "codex:x:${toString uid}:" >> $out/etc/group
    echo "hosts: files dns" > $out/etc/nsswitch.conf
    cat > $out/etc/nix/nix.conf <<'EOF'
    sandbox = false
    filter-syscalls = false
    experimental-features = nix-command flakes
    accept-flake-config = true
    EOF
  '';

  # This is also referenced by the launcher. dockerTools image archives do not retain Nix
  # references, and /nix/store is replaced by the host mount at runtime, so keeping this
  # environment in the system closure prevents GC from removing an image command's target.
  runtime = pkgs.buildEnv {
    name = "codex-container-runtime";
    paths = with pkgs; [
      codex
      nix
      git
      git-lfs
      openssh
      ripgrep
      curl
      bashInteractive
      coreutils
      findutils
      gnugrep
      gnused
      gawk
      diffutils
      patch
      file
      less
      cacert
      ncurses
      dockerTools.usrBinEnv
      dockerTools.binSh
      passwdEtc
    ];
  };
in
(pkgs.dockerTools.buildLayeredImage {
  name = "localhost/ccodex";
  tag = "latest";
  contents = [ runtime ];

  fakeRootCommands = ''
    mkdir -p .${homeDir} .tmp
    chown -R ${toString uid}:${toString uid} .${homeDir}
    chmod 1777 .tmp
  '';
  enableFakechroot = true;

  config = {
    Cmd = [
      "/bin/codex"
      "--yolo"
    ];
    User = toString uid;
    WorkingDir = homeDir;
    Env = [
      "HOME=${homeDir}"
      "USER=codex"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_REMOTE=daemon"
      "PATH=/bin:/nix/var/nix/profiles/default/bin:/nix/var/nix/profiles/system/sw/bin"
      "LANG=C.UTF-8"
      "TERMINFO_DIRS=/share/terminfo"
    ];
  };
})
// {
  inherit runtime;
}
