#!/usr/bin/env bash
#
# Bootstrap every secret the family WireGuard networks need, without any of that
# plaintext ever reaching a terminal, a command line, or shell history.
#
# Produces:
#   .sops.yaml                  two age recipients + creation rules (main, family)
#   secrets/family-age-key.enc  the family age private key, passphrase-wrapped
#   secrets/family.yaml         per-device WireGuard keys + password hashes
#   secrets/secrets.yaml        the existing file, plus four hub/admin keys and root's hash
#
# and prints ONLY the WireGuard public keys and the family age recipient, which are
# neither secret nor identifying and belong in git (modules/family/peers.nix).
#
# WHY THE CONTORTIONS. Three ways secrets leak that are easy to miss:
#   1. argv is world-readable via /proc — `mkpasswd -m sha-512 "$pw"` and
#      `sops --set '["k"]' "$v"` both hand the secret to every user on the box for as
#      long as the process lives. Everything here goes over stdin or through a file.
#   2. Anything echoed lands in scrollback, and in the transcript if an agent runs it.
#   3. shred(1) cannot overwrite in place on a copy-on-write filesystem, which is what
#      sulfur's /tmp sits on. $WORK is therefore on /dev/shm (tmpfs, RAM only).
#
# Needs a TTY: it prompts for six passwords and an age passphrase. Run it yourself.
#
# NOTHING IS WRITTEN TO THE CHECKOUT until step 8; abort before then and the repository
# is exactly as you found it.
# Re-running ROTATES EVERY KEY -- every peer config and every password changes.
#
set -euo pipefail

# The existing age recipient, sole reader of secrets/secrets.yaml. Taken from that
# file's own sops metadata; if you ever rotate it, change it here too.
MAIN_RECIPIENT="age1276ku650f9gsmv3slnduus8styr0m6ued8dpza2qau446sp9l4qsq5dden"

# WireGuard keypairs, all keyed `wg-priv-<name>` to match the existing wg-priv-sulfur /
# wg-priv-fleet convention. The split is only which FILE they land in: HUB_PEERS go to
# secrets/secrets.yaml (main key), FAMILY_PEERS to secrets/family.yaml (main + family),
# so a kid's laptop can read its own key and nothing else.
#
# FAMILY_PEERS are hostnames -- the kids' Minecraft handles, lowercased. Keep them in
# step with `family` in modules/family/peers.nix.
HUB_PEERS=(wgfam-hub wgadm-hub sulfur-adm osmium-fam)
FAMILY_PEERS=(gentlemenpupil vizualwanderer phantomspecialst maddreamer)

# Accounts needing a hashed password, keyed `<name>-password-hash` (matching
# nextcloud-adminpass / paperless-adminpass).
#
# sheath's goes in secrets/family.yaml alongside the kids' even though sheath is not a
# family device, because that file is encrypted to BOTH recipients: hydrogen and sulfur
# read it with the main key, the laptops with the family key, and there is exactly one
# hash to keep current. It matters on every one of those hosts because they all run
# users.mutableUsers = false, under which an account with no declared hash is locked --
# not blank -- and the console login is the recovery path when the network is what broke.
FAMILY_PASSWORD_KEYS=("${FAMILY_PEERS[@]}" sheath)

# root, for hydrogen only, and therefore in secrets/secrets.yaml (main key) -- the kids'
# laptops leave root locked on purpose.
#
# It exists because turning on users.mutableUsers = false for hydrogen also DISCARDS the
# root password that was set interactively at install: under that setting the declared
# state is the whole state. Without this, hydrogen's systemd emergency shell would have
# no way in, and a server that cannot be rescued from its own console is a bad trade for
# a tidier password story. (sulfur already declares root via /persist/secrets/root-password
# and is unaffected.)
MAIN_PASSWORD_KEYS=(root)

die() { echo "error: $*" >&2; exit 1; }

[[ -f flake.nix && -d secrets ]] || die "run this from the repository root"
[[ -t 0 ]] || die "needs a TTY (it prompts for passwords)"
for c in wg age age-keygen sops mkpasswd shred; do
    command -v "$c" >/dev/null || die "missing required tool: $c"
done

# Refuse to silently rotate. Rotation is a legitimate operation, just never an accident.
if [[ -e secrets/family.yaml || -e secrets/family-age-key.enc ]] && [[ "${1:-}" != "--rotate" ]]; then
    die "secrets/family.yaml already exists. Re-run with --rotate to replace every key."
fi

# Fail before doing any work, not after six password prompts. Step 7 rewrites
# secrets/secrets.yaml, which means decrypting it first -- impossible without the main
# age key, and a failure there would leave a half-updated repository.
if ! sops -d secrets/secrets.yaml >/dev/null 2>&1; then
    die "cannot decrypt secrets/secrets.yaml -- run this on a host holding the main age key
       (normally ~/.config/sops/age/keys.txt). Nothing has been changed."
fi

umask 077
WORK="$(mktemp -d -p /dev/shm family-secrets.XXXXXX)"
cleanup() {
    # Best-effort: on tmpfs the pages are freed either way, but shred first so a
    # swapped-out page is overwritten too.
    find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# sops picks its recipients by matching creation rules against the *filename*, so the
# staging files are laid out under the paths they will end up at.
mkdir -p "$WORK/secrets"

# --- 1. WireGuard keypairs -------------------------------------------------------
# Private key is written by redirection and read by redirection; it is never the value
# of a variable and never an argument.
echo "Generating WireGuard keypairs..."
for p in "${HUB_PEERS[@]}" "${FAMILY_PEERS[@]}"; do
    wg genkey > "$WORK/$p.key"
    wg pubkey < "$WORK/$p.key" > "$WORK/$p.pub"
done

# --- 2. Family age key -----------------------------------------------------------
# age-keygen puts the private key in the file and announces the recipient on stderr.
echo "Generating the family age key..."
age-keygen -o "$WORK/family-age.key" 2> "$WORK/family-age.log"
FAMILY_RECIPIENT="$(grep -o 'age1[0-9a-z]*' "$WORK/family-age.log" | head -1)"
[[ -n "$FAMILY_RECIPIENT" ]] || die "could not read the generated age recipient"

# --- 3. Passphrase-wrap the age key, BEFORE anything reaches the repository -------
# This step is here rather than at the end because it is the only one that can fail on
# user input, and everything after it depends on the key it protects. A run that died at
# this prompt used to leave .sops.yaml and secrets/family.yaml already written, naming a
# family recipient whose private half had just been shredded from $WORK on exit --
# an unusable pair of files and no way to tell from looking at them. (This is not
# hypothetical; it happened on 2026-08-06.)
#
# Armored + scrypt, matching secrets/age-key.enc exactly. install.sh decrypts this onto
# each family laptop, so the passphrase is the only thing an install needs that is not in
# the repository. Pick a strong one: this file is committed to a PUBLIC repository and is
# all that protects the family WireGuard keys and password hashes.
echo
echo "Choose a passphrase for secrets/family-age-key.enc (needed at every install)."
age -p -a -o "$WORK/family-age-key.enc" "$WORK/family-age.key"

# --- 4. .sops.yaml ---------------------------------------------------------------
# Staged in $WORK and passed to sops with --config, so the repository is untouched until
# every artefact exists. Rules are evaluated top-down, first match wins.
cat > "$WORK/.sops.yaml" <<EOF
# sops creation rules. Which key can read which file is the whole point:
# secrets/secrets.yaml holds credentials for hydrogen's services (Nextcloud admin, Borg
# repo key, fleet VPN SSH key) and stays readable only by the main key. The family
# laptops carry the FAMILY key instead, so a kid's machine -- which lives outside the
# house and is not disk-encrypted -- can decrypt its own WireGuard key and password and
# nothing else.
#
# Rotate a recipient here and re-run \`sops updatekeys <file>\` on every file it matches.
keys:
  - &main ${MAIN_RECIPIENT}
  - &family ${FAMILY_RECIPIENT}

creation_rules:
  # Family devices: readable by the family key AND by main, so hydrogen and sulfur can
  # still administer them.
  - path_regex: secrets/family\.yaml\$
    key_groups:
      - age:
          - *main
          - *family

  # Everything else: main only.
  - path_regex: secrets/[^/]+\.yaml\$
    key_groups:
      - age:
          - *main
EOF

# --- 5. Passwords ----------------------------------------------------------------
# read -rs keeps them off the screen; printf is a shell builtin, so the plaintext is
# piped to mkpasswd rather than appearing in its argv.
echo
echo "Set a login password for each account (input hidden)."
echo "  <handle>  the child's login on their own laptop"
echo "  sheath    your login on hydrogen, sulfur and all four laptops"
echo "  root      hydrogen's emergency-console login only"
for k in "${FAMILY_PASSWORD_KEYS[@]}" "${MAIN_PASSWORD_KEYS[@]}"; do
    while :; do
        read -rsp "  password for ${k}: " pw; echo
        read -rsp "  confirm         : " pw2; echo
        [[ "$pw" == "$pw2" ]] && [[ -n "$pw" ]] && break
        echo "  -> empty or mismatched, try again"
    done
    printf '%s\n' "$pw" | mkpasswd -m sha-512 -s > "$WORK/$k.hash"
    unset pw pw2
done

# --- 6. secrets/family.yaml ------------------------------------------------------
# Composed as a whole file and encrypted in one shot. Command substitution happens
# inside this shell, so no secret is ever an argument to anything.
{
    echo "# Family device secrets. Readable by the family age key (see .sops.yaml)."
    for p in "${FAMILY_PEERS[@]}"; do
        printf 'wg-priv-%s: %s\n' "$p" "$(cat "$WORK/$p.key")"
    done
    for k in "${FAMILY_PASSWORD_KEYS[@]}"; do
        printf '%s-password-hash: %s\n' "$k" "$(cat "$WORK/$k.hash")"
    done
} > "$WORK/secrets/family.yaml"

sops --config "$WORK/.sops.yaml" -e --filename-override secrets/family.yaml \
    "$WORK/secrets/family.yaml" > "$WORK/family.yaml.enc"

# --- 7. secrets/secrets.yaml -----------------------------------------------------
# Decrypt, append, re-encrypt. `sops -d` strips the old metadata, and the creation rule
# written above supplies the recipient -- which is the same one it already had.
# Strip every key this run is about to write, then append. Without the strip, a --rotate
# would append a second `wg-priv-wgfam-hub:` next to the existing one and hand sops a YAML
# document with duplicate mapping keys -- which does not error, it silently keeps one of
# them. This makes the whole script idempotent: run it as many times as you like.
#
# `sheath_password_hash` is in the list for a different reason: it is a leftover from an
# older attempt at declarative passwords that no .nix file has ever referenced, and its
# replacement (`sheath-password-hash`, in secrets/family.yaml) differs from it only by an
# underscore. Two near-identical names, in two files, read by two different keys, is a
# mistake waiting to happen. It is dropped and not re-added.
DROP_KEYS=(sheath_password_hash)
for p in "${HUB_PEERS[@]}"; do DROP_KEYS+=("wg-priv-$p"); done
for k in "${MAIN_PASSWORD_KEYS[@]}"; do DROP_KEYS+=("$k-password-hash"); done
DROP_RE="^($(IFS='|'; echo "${DROP_KEYS[*]}")):"

sops -d secrets/secrets.yaml | grep -vE "$DROP_RE" > "$WORK/secrets/secrets.yaml"
{
    for p in "${HUB_PEERS[@]}"; do
        printf 'wg-priv-%s: %s\n' "$p" "$(cat "$WORK/$p.key")"
    done
    for k in "${MAIN_PASSWORD_KEYS[@]}"; do
        printf '%s-password-hash: %s\n' "$k" "$(cat "$WORK/$k.hash")"
    done
} >> "$WORK/secrets/secrets.yaml"

sops --config "$WORK/.sops.yaml" -e --filename-override secrets/secrets.yaml \
    "$WORK/secrets/secrets.yaml" > "$WORK/secrets.yaml.enc"

# --- 8. Commit everything to the repository, last ---------------------------------
# Four files, all already built and validated in $WORK. Nothing above this line has
# modified the checkout, so an abort at any earlier point leaves it exactly as found.
install -m 0644 "$WORK/.sops.yaml"           .sops.yaml
install -m 0600 "$WORK/family.yaml.enc"      secrets/family.yaml
install -m 0600 "$WORK/secrets.yaml.enc"     secrets/secrets.yaml
install -m 0644 "$WORK/family-age-key.enc"   secrets/family-age-key.enc
echo
echo "Wrote .sops.yaml, secrets/family.yaml, secrets/secrets.yaml, secrets/family-age-key.enc"

# --- 9. The only output ----------------------------------------------------------
echo
echo "=================================================================="
echo " Public material -- safe to commit. Paste into modules/family/peers.nix."
echo "=================================================================="
for p in "${HUB_PEERS[@]}" "${FAMILY_PEERS[@]}"; do
    printf '  %-18s %s\n' "$p" "$(cat "$WORK/$p.pub")"
done
echo
echo "  family age recipient (already written into .sops.yaml):"
echo "    ${FAMILY_RECIPIENT}"
echo
echo "Next: fill in modules/family/peers.nix, then commit .sops.yaml,"
echo "secrets/family.yaml, secrets/family-age-key.enc and secrets/secrets.yaml."
