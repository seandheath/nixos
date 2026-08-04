{ pkgs, prismRoot }:
# minecraft-mods-link <instance> -- point a Prism instance's mods folder at the
# Nix-managed jar set in packages/minecraft-client-mods.nix.
#
# Used two ways:
#   - by hand on sulfur, once per instance (docs/minecraft.md), and
#   - from minecraft-couch-sync on hydrogen, which re-runs it on every sync so the
#     couch instance cannot fall behind a rebuild.
#
# CONSEQUENCE, deliberate: mods/ becomes a read-only store path, so Prism's GUI can
# no longer install a mod into this instance. That is the trade for having one list
# drive both machines -- add mods in Nix instead. Prism only ever writes into mods/
# when installing, so browsing the Mods tab is unaffected.
let
  clientMods = import ./minecraft-client-mods.nix { inherit pkgs; };
in
pkgs.writeShellApplication {
  name = "minecraft-mods-link";
  runtimeInputs = with pkgs; [
    coreutils
    findutils
  ];
  text = ''
    mods="${clientMods}"
    prism="${prismRoot}"

    inst="''${1:-}"
    if [ -z "$inst" ] || [ "$#" -gt 1 ]; then
      echo "usage: minecraft-mods-link <prism-instance-name>" >&2
      echo "  e.g. minecraft-mods-link couch      (hydrogen)" >&2
      echo "       minecraft-mods-link Hydrogen   (sulfur)" >&2
      exit 2
    fi

    if [ ! -d "$prism/instances/$inst" ]; then
      echo "minecraft-mods-link: no Prism instance '$inst' in $prism." >&2
      echo "Create it in Prism first -- see docs/minecraft.md." >&2
      exit 1
    fi

    dot="$prism/instances/$inst/.minecraft"
    mkdir -p "$dot"
    target="$dot/mods"

    if [ -L "$target" ]; then
      # Ours from a previous run (or an older store path). Just re-point it.
      rm -f "$target"
    elif [ -d "$target" ]; then
      if [ -n "$(ls -A "$target")" ]; then
        # A real directory with jars in it -- almost certainly GUI-installed mods
        # from before this was declarative. Never delete those silently; stash them
        # once, using the same .stateful convention the nixpkgs minecraft-server
        # module uses when it takes over server.properties.
        backup="$dot/mods.stateful"
        if [ -e "$backup" ]; then
          echo "minecraft-mods-link: $target is a non-empty directory and" >&2
          echo "$backup already exists, so there is nowhere safe to stash it." >&2
          echo "Move or delete one of them by hand, then re-run." >&2
          exit 1
        fi
        mv "$target" "$backup"
        echo "minecraft-mods-link: stashed the previous mods/ at $backup"
      else
        rmdir "$target"
      fi
    fi

    ln -s "$mods" "$target"
    echo "minecraft-mods-link: $inst -> $mods"
    find "$mods"/ -mindepth 1 -maxdepth 1 -printf '  %f\n' | sort
  '';
}
