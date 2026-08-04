{ pkgs }:

# Container image for the sandboxed RE agents (`cqwen` / `copencode`, see
# modules/re-container.nix). Both agents are driven by a remote model and handed a shell
# tool, so this bounds what a rogue or confused one can reach on the host.
#
# Why dockerTools.buildLayeredImage rather than a Containerfile:
#   cclaude (the reference this is modelled on) builds from debian:bookworm-slim and
#   installs Claude Code with a curl-to-bash installer, because that is how Claude Code
#   ships. Both agents here already exist as Nix packages — including the version-pinned
#   packages/qwen-code.nix — so building the image from those is reproducible, needs no
#   network at build time, and cannot drift from what `qwen`/`opencode` are on the host.
#
# Contents are deliberately minimal: a rogue agent can only execute what is in this list,
# and there is no /nix/store mount or nix daemon socket to widen it (unlike cclaude, which
# mounts both so Claude can run `nix develop`).
let
  qwen-code = import ./qwen-code.nix { inherit pkgs; };

  # HOME and the config tree live here. Deliberately not /home/sheath: nothing in the
  # container should be able to guess-path its way into a host-shaped home directory.
  homeDir = "/home/re";
  uid = 1000;

  # `--userns=keep-id` maps the invoking user to the same uid inside the container, but
  # dockerTools images have no /etc/passwd, and several tools (git, and node's os.userInfo(),
  # which qwen-code calls) fail or misbehave without an entry for the running uid.
  passwdEtc = pkgs.runCommand "re-container-etc" { } ''
    mkdir -p $out/etc
    echo "root:x:0:0:root:/root:/bin/bash"        > $out/etc/passwd
    echo "re:x:${toString uid}:${toString uid}:RE agent:${homeDir}:/bin/bash" >> $out/etc/passwd
    echo "root:x:0:"                              > $out/etc/group
    echo "re:x:${toString uid}:"                  >> $out/etc/group
    echo "hosts: files dns"                       > $out/etc/nsswitch.conf
  '';

  # Copies qwen-code's config out of the read-only /run/config mount into $HOME.
  #
  # Only qwen-code needs the copy, and only for these two files: it **rewrites its own
  # settings.json on startup** (schema migration + a "$version" stamp — established when
  # the host install was built), which fails against a read-only bind mount. OpenCode only
  # ever reads its config, so modules/re-container.nix mounts that one read-only in place
  # and it never passes through here.
  #
  # Note what is deliberately absent: `.env`. The three endpoint secrets are passed as
  # environment variables by the launcher instead, so no secret is ever written into the
  # persistent home volume. qwen-code resolves the `$OPENWEBUI_*` placeholders in
  # settings.json from the process environment just as happily as from a .env file
  # (verified in-container), and `envKey` reads the same environment.
  entrypoint = pkgs.writeShellApplication {
    name = "re-entrypoint";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # Each file is optional so a shell session still works with no config mounted.
      install -d -m 700 "$HOME/.qwen"
      for f in settings.json QWEN.md; do
        [ -e "/run/config/qwen/$f" ] && install -m 600 "/run/config/qwen/$f" "$HOME/.qwen/$f"
      done

      exec "$@"
    '';
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/re-agents";
  tag = "latest";

  contents = [
    qwen-code
    pkgs.opencode

    # python3 is REQUIRED, not a convenience: prompts/re-agent.md tells the agent to shell
    # out to `python3 -c` for all hex/bitwise/sign/endianness work, and both clients
    # pre-approve exactly that command form. Without it in the image the agent falls back
    # to computing in its head, which is the failure the prompt exists to prevent.
    pkgs.python3

    # Reading a reference source tree (see the "Reference source" section of the prompt).
    # Both agents have ripgrep-backed search tools of their own, but they also shell out to
    # ordinary text utilities, and a missing grep surfaces as a confusing tool failure rather
    # than a clear "not installed". These are read/transform tools; coreutils is already here,
    # so they do not meaningfully widen what a rogue agent can do.
    pkgs.git
    pkgs.ripgrep
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gawk
    pkgs.findutils
    pkgs.less

    pkgs.bashInteractive
    pkgs.coreutils

    # ncurses is here for its **terminfo database**, not for tput. A dockerTools image ships
    # no terminfo at all (cclaude gets one free from debian's ncurses-base), so TERM=
    # xterm-256color resolves to nothing, both TUIs lose cursor addressing, and they fall
    # back to clearing and repainting the whole screen every frame — which reads as violent
    # flicker in ptyxis. See TERMINFO_DIRS in config.Env below; both halves are required.
    pkgs.ncurses
    # HTTPS to the vLLM endpoint. Without this every model call fails cert verification.
    pkgs.cacert
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh

    passwdEtc
    entrypoint
  ];

  # $HOME is a named volume mounted at runtime with podman's `,U` (chown to the container
  # user); the mountpoint still has to exist in the image for a read-only rootfs.
  #
  # A tmpfs was tried first, to keep the home purely ephemeral, and abandoned: podman's
  # --tmpfs rejects `uid=`, so the tmpfs lands owned by the namespace root and the uid-1000
  # agent cannot write to it. The volume is the same mechanism cclaude uses, and it buys
  # persistent session history. Nothing secret is written there — see the entrypoint note.
  fakeRootCommands = ''
    mkdir -p .${homeDir} .tmp
    chown -R ${toString uid}:${toString uid} .${homeDir}
    chmod 1777 .tmp
  '';
  enableFakechroot = true;

  config = {
    Entrypoint = [ "/bin/re-entrypoint" ];
    Cmd = [ "/bin/bash" ];
    User = toString uid;
    WorkingDir = homeDir;
    Env = [
      "HOME=${homeDir}"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "PATH=/bin"
      "LANG=C.UTF-8"
      # dockerTools unpacks package outputs at the image root, so ncurses' terminfo tree
      # lands at /share/terminfo rather than the /usr/share/terminfo that ncurses compiles
      # in as its default search path. Without this the database above is present but never
      # found, which looks identical to not having it. TERM itself comes from the launcher.
      "TERMINFO_DIRS=/share/terminfo"
    ];
  };
}
