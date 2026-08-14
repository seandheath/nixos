#!/usr/bin/env bash
#
# Provision a phone or tablet onto the family WireGuard networks, as a QR code.
#
#   ./gen-mobile-peer.sh <name> adult|family
#
# Prints a QR the WireGuard app scans, then the two config snippets to paste into
# modules/family/peers.nix and the nixrouter repo.
#
# DNS COMES FROM THE ROUTER, over the router peer -- not from hydrogen. There is exactly
# one authority for these names. hydrogen briefly ran a second dnsmasq for the same zone,
# which is how split-horizon DNS starts giving two different answers to one question.
#
# So the phone asks the router at its tunnel address for a name, is told where the app
# lives, and reaches it over the hydrogen peer. Two peers, each doing its own job, and
# neither box's outage implies the other's.
#
# THE SECOND DNS SERVER IS NOT OPTIONAL. With only the tunnel resolver listed, a phone
# whose hydrogen peer is down has no DNS at all -- not degraded, gone -- and presents as
# "the internet is broken" to someone who will not debug it. That happened on 2026-08-06:
# a phone paired before the router's split-horizon record was deployed pinned a stale
# endpoint, never handshook with hydrogen, and lost all name resolution while the network
# itself was fine. The fallback turns that into "Immich does not resolve", which is a
# complaint rather than an outage.
#
# The cost is that on failover the phone briefly resolves through 1.1.1.1 instead of
# AdGuard, losing filtering until the tunnel recovers. For an adult's phone that is the
# right trade; do not copy this to a child's device.
#
# RUN THIS IN A PLAIN TERMINAL, NOT THROUGH AN AGENT AND NOT VIA `!`.
# The QR encodes the whole config, private key included. Rendered as terminal blocks it
# is just as readable to a camera as to a phone, and anything that captures your terminal
# output captures the key with it. Scan it, then clear the screen.
#
# WHY THE KEY IS GENERATED HERE rather than on the device. Letting the phone generate its
# own keypair is strictly better -- the private half never exists anywhere else -- but it
# costs you hand-entering an address, a DNS server, two endpoints, two public keys and
# two AllowedIPs lists on a touchscreen, where one wrong character yields a tunnel that
# fails silently. This machine is the admin box, the key lives in /dev/shm for a few
# seconds, and nothing is written to disk. If you would rather do it the other way, run
# the app's key generator and send me the public half instead; the module side is the
# same either way.
#
set -euo pipefail

# --- Hub facts, read from modules/family/peers.nix ---------------------------------
# Derived, not transcribed. This block used to be a hand-copied duplicate, and it drifted:
# it sent every phone to hub.luckyobserver.com, a name peers.nix records as deliberately
# abandoned in favour of vpn.
eval "$(nix eval --json --file modules/family/peers.nix 2>/dev/null | ${PYTHON:-python3} -c '
import json, sys, shlex
d = json.load(sys.stdin)
def emit(k, v): print(f"{k}={shlex.quote(str(v))}")
emit("HYDROGEN_FAM_KEY", d["hubs"]["fam"]["publicKey"])
emit("HYDROGEN_ADM_KEY", d["hubs"]["adm"]["publicKey"])
emit("ROUTER_MGMT_KEY",  d["routerMgmt"]["publicKey"])
emit("FAM_PORT",         d["hubs"]["fam"]["port"])
emit("ADM_PORT",         d["hubs"]["adm"]["port"])
emit("MGMT_PORT",        d["routerMgmt"]["port"])
emit("HYDROGEN_HOST",    d["endpointHost"])
emit("ROUTER_HOST",      d["endpointHost"])
emit("ROUTER_TUNNEL_ADDR", d["routerMgmt"]["address"])
')"
[[ -n ${HYDROGEN_FAM_KEY:-} ]] || { echo "error: could not read modules/family/peers.nix" >&2; exit 1; }

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <name> adult|family"
NAME=$1
CLASS=$2

[[ -f flake.nix ]] || die "run this from the repository root"
[[ -t 1 ]] || die "refusing to run without a terminal -- the QR is the output"
for c in wg qrencode shred; do
    command -v "$c" >/dev/null || die "missing $c (try: nix shell nixpkgs#qrencode)"
done

# --- What this class of device gets ----------------------------------------------
#
# AllowedIPs must not overlap between peers on one interface -- WireGuard routes by
# longest match across the whole peer set, so a duplicate entry silently belongs to
# whichever peer was parsed last.
#
# 10.0.0.1 IS DELIBERATELY ABSENT and must stay that way. It is the device's own default
# gateway whenever it is on home wifi; routing it into the tunnel takes the device's
# network out completely. That is not a theory -- it happened to sulfur on 2026-08-06.
# The router is reached at its tunnel address instead, and hydrogen's resolver answers
# kids.lan with that address for anyone already inside.
case "$CLASS" in
  adult)
    # wgadm: the services, plus SSH/RustDesk/Syncthing reach. Yours.
    read -rp "  tunnel address for ${NAME} (e.g. 10.42.0.4 -- .1/.2/.3 are router/hydrogen/sulfur): " ADDR
    HUB_KEY=$HYDROGEN_ADM_KEY
    HUB_PORT=$ADM_PORT
    HUB_ALLOWED="10.42.0.2/32, 10.41.0.2/32"   # admin address + the service address
    DNS_ADDR="${ROUTER_TUNNEL_ADDR}, 1.1.1.1"
    ;;
  family)
    # wgfam: web services and Minecraft only, isolated from every other peer.
    read -rp "  tunnel address for ${NAME} (e.g. 10.41.0.21): " ADDR
    HUB_KEY=$HYDROGEN_FAM_KEY
    HUB_PORT=$FAM_PORT
    HUB_ALLOWED="10.41.0.2/32"
    DNS_ADDR="${ROUTER_TUNNEL_ADDR}, 1.1.1.1"
    ;;
  *) die "class must be 'adult' or 'family'" ;;
esac

[[ "$ADDR" =~ ^10\.4[12]\.0\.[0-9]+$ ]] || die "'$ADDR' is not a 10.41.0.x / 10.42.0.x address"

umask 077
WORK="$(mktemp -d -p /dev/shm mobile-peer.XXXXXX)"
cleanup() {
    find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

wg genkey > "$WORK/priv"
wg pubkey < "$WORK/priv" > "$WORK/pub"

# Composed by redirection; the private key is never an argument to anything.
{
    echo "[Interface]"
    echo "PrivateKey = $(cat "$WORK/priv")"
    echo "Address = ${ADDR}/32"
    echo "DNS = ${DNS_ADDR}"
    echo
    echo "[Peer]"
    echo "# hydrogen"
    echo "PublicKey = ${HUB_KEY}"
    echo "AllowedIPs = ${HUB_ALLOWED}"
    echo "Endpoint = ${HYDROGEN_HOST}:${HUB_PORT}"
    echo "PersistentKeepalive = 25"
    echo
    echo "[Peer]"
    echo "# router -- kids.lan and adguard.lan"
    echo "PublicKey = ${ROUTER_MGMT_KEY}"
    echo "AllowedIPs = ${ROUTER_TUNNEL_ADDR}/32"
    echo "Endpoint = ${ROUTER_HOST}:${MGMT_PORT}"
    echo "PersistentKeepalive = 25"
} > "$WORK/wg.conf"

clear
echo "Scan with the WireGuard app  ->  Add tunnel  ->  Create from QR code"
echo
qrencode -t ANSIUTF8 < "$WORK/wg.conf"
echo
read -rp "Scanned? Press Enter to wipe the QR from the screen... " _
clear

echo "=================================================================="
echo " ${NAME} (${CLASS}) -- ${ADDR}"
echo "=================================================================="
echo
echo "modules/family/peers.nix, in \`mobile\`:"
echo "    ${NAME} = {"
echo "      address = \"${ADDR}\";"
echo "      publicKey = \"$(cat "$WORK/pub")\";"
echo "    };"
echo
echo "nixrouter config.nix, in \`wireguardMgmt.peers\`:"
echo "    { name = \"${NAME}\"; publicKey = \"$(cat "$WORK/pub")\"; allowedIp = \"${ADDR}/32\"; }"
echo
echo "Then rebuild hydrogen and the router. The device cannot connect until both"
echo "have switched -- it is not enrolled anywhere until its key is registered."
