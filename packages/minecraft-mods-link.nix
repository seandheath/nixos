{ pkgs, prismRoot }:
# minecraft-mods-link <instance> -- point a Prism instance's mods folder at the
# Nix-managed jar set in packages/minecraft-client-mods.nix.
#
# Used three ways:
#   - automatically, from the minecraft-mods-link.service oneshot in
#     modules/minecraft-mods.nix, which re-runs on boot and on any switch that
#     changes the jar set (the store path is baked into the unit, so a changed mod
#     list changes the unit and switch restarts it),
#   - from minecraft-couch-sync on hydrogen, which re-links before fanning the
#     instance out to each player, and
#   - by hand, which is what you want right after creating an instance -- the
#     service only re-runs on boot or on a *change*, so it will not notice a new
#     instance appearing under an otherwise unchanged configuration.
#
# Idempotent and cheap: if the link already points at the current store path it
# reports that and exits without touching anything, which is what makes it safe to
# run unconditionally on every boot.
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
    defaults="${clientMods.configDefaults}"
    prism="${prismRoot}"

    # --if-present: a missing instance is a skip, not an error. The service uses this
    # so a host that has not had its Prism instance created yet (hydrogen's "couch",
    # for most of this setup's life) does not show a failed unit after every switch.
    optional=0
    if [ "''${1:-}" = "--if-present" ]; then
      optional=1
      shift
    fi

    inst="''${1:-}"
    if [ -z "$inst" ] || [ "$#" -gt 1 ]; then
      echo "usage: minecraft-mods-link [--if-present] <prism-instance-name>" >&2
      echo "  e.g. minecraft-mods-link couch      (hydrogen)" >&2
      echo "       minecraft-mods-link Hydrogen   (sulfur)" >&2
      exit 2
    fi

    if [ ! -d "$prism/instances/$inst" ]; then
      if [ "$optional" -eq 1 ]; then
        echo "minecraft-mods-link: no Prism instance '$inst' yet, nothing to link."
        exit 0
      fi
      echo "minecraft-mods-link: no Prism instance '$inst' in $prism." >&2
      echo "Create it in Prism first -- see docs/minecraft.md." >&2
      exit 1
    fi

    # The game root is NOT always .minecraft. Prism 11 creates instances with a
    # plain "minecraft/" directory and only falls back to the dotted name for
    # instances inherited from MultiMC. Guessing wrong is quiet and confusing: the
    # link lands in a directory Prism never reads, the Mods tab shows an empty list,
    # and a stray .minecraft/ is left behind next to the real game root. Resolve it
    # the way Prism does instead. (modules/minecraft-couch.nix repeats this rule for
    # its rsync excludes -- keep the two in step.)
    root="$prism/instances/$inst"
    if [ -d "$root/minecraft" ]; then
      dot="$root/minecraft"
    elif [ -d "$root/.minecraft" ]; then
      dot="$root/.minecraft"
    else
      # Neither exists yet (instance created but never launched). Prism 11 would
      # make the undotted one.
      dot="$root/minecraft"
      mkdir -p "$dot"
    fi
    target="$dot/mods"

    # Seed default mod configs, never overwriting. See configDefaults in
    # packages/minecraft-client-mods.nix for why each one is there.
    # minecraft-couch-sync does the same for each player's own config dir.
    #
    # Deliberately BEFORE the up-to-date early exit below: adding a new default to
    # an unchanged mod set must still reach an instance that is already linked.
    mkdir -p "$dot/config"
    for src in "$defaults"/*; do
      [ -e "$src" ] || continue
      dst="$dot/config/$(basename "$src")"
      if [ ! -e "$dst" ]; then
        install -m0644 "$src" "$dst"
        echo "minecraft-mods-link: seeded config/$(basename "$src")"
      fi
    done

    # Already correct -- do nothing further. Keeps the boot-time run silent and makes
    # an unnecessary switch a no-op rather than a churn of rm/ln on the user's instance.
    if [ "$(readlink "$target" 2>/dev/null || true)" = "$mods" ]; then
      echo "minecraft-mods-link: $inst already up to date."
      exit 0
    fi

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
