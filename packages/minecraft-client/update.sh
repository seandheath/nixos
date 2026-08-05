#!/usr/bin/env bash
# Regenerate libraries.json -- the pinned inventory of everything the Minecraft
# client needs to run. Run it after changing MC_VERSION, then rebuild; the assets
# fixed-output derivation in default.nix will report its new hash, which has to be
# pasted back into that file (see the ASSETS HASH note there).
#
#   ./packages/minecraft-client/update.sh 1.21.10
#
# WHY A GENERATED LOCKFILE rather than fetchurl calls written by hand, the way
# packages/fabric-server.nix pins its eight loader jars: the client's version JSON
# lists 115 libraries. Transcribing those by hand would be error-prone and would have
# to be redone in full on every Minecraft bump. The output is committed, so Nix reads
# a repo file and no import-from-derivation is involved.
#
# Mojang publishes sha1 for every artifact, which is what goes into the lockfile
# (converted to SRI). Weak as a security hash, but these are pins for reproducibility
# against a CDN we also verify by TLS -- and it is the only hash upstream gives us
# without downloading all 82 MB twice.
set -euo pipefail

mc="${1:-1.21.10}"
out="$(dirname "$0")/libraries.json"

manifest="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

sri() { nix hash convert --hash-algo sha1 --to sri "$1"; }

echo "update.sh: resolving Minecraft $mc" >&2
version_url="$(curl -sSfL "$manifest" | jq -r --arg v "$mc" '.versions[] | select(.id==$v) | .url')"
[ -n "$version_url" ] || { echo "update.sh: no such version: $mc" >&2; exit 1; }

version_json="$(curl -sSfL "$version_url")"

# The version JSON's own sha1 matters: portablemc re-checks it against the manifest
# whenever it can reach the network, and refetches if it differs (standard.py:393-412).
# Mojang embeds that same sha1 in the URL path, so take it from there.
version_sha1="$(basename "$(dirname "$version_url")")"

assets_id="$(jq -r '.assets' <<<"$version_json")"

# Every library, including the ones whose rules exclude Linux. Fetching the lot costs
# ~82 MB instead of ~55 MB and means the payload cannot go wrong if portablemc's rule
# evaluation ever disagrees with ours about what this platform needs.
jq -n \
  --arg mc "$mc" \
  --arg assetsId "$assets_id" \
  --arg versionUrl "$version_url" \
  --arg versionHash "$(sri "$version_sha1")" \
  --argjson v "$version_json" \
  --argjson libs "$(jq '[.libraries[] | select(.downloads.artifact) | .downloads.artifact
                         | {path, url, sha1, size}]' <<<"$version_json")" \
  '{
     mcVersion: $mc,
     javaVersion: $v.javaVersion.majorVersion,
     assetIndexId: $assetsId,
     versionJson: { url: $versionUrl, hash: $versionHash },
     clientJar:   { url: $v.downloads.client.url, sha1: $v.downloads.client.sha1, size: $v.downloads.client.size },
     assetIndex:  { url: $v.assetIndex.url, sha1: $v.assetIndex.sha1, size: $v.assetIndex.size,
                    totalSize: $v.assetIndex.totalSize },
     # The log4j2 config the game is launched with (-Dlog4j.configurationFile). Small,
     # easy to miss, and its absence is the difference between launching offline and
     # not: portablemc schedules it like any other download.
     logConfig:   { id: $v.logging.client.file.id, url: $v.logging.client.file.url,
                    sha1: $v.logging.client.file.sha1, size: $v.logging.client.file.size },
     libraries: $libs,
   }' > "$out.tmp"

# Convert every hex sha1 to SRI in one pass -- jq cannot do base64 of raw bytes.
python3 - "$out.tmp" "$out" <<'PY'
import base64, json, sys

src, dst = sys.argv[1], sys.argv[2]
doc = json.load(open(src))


def sri(hex_sha1: str) -> str:
    return "sha1-" + base64.b64encode(bytes.fromhex(hex_sha1)).decode()


for key in ("clientJar", "assetIndex", "logConfig"):
    doc[key]["hash"] = sri(doc[key].pop("sha1"))
for lib in doc["libraries"]:
    lib["hash"] = sri(lib.pop("sha1"))

json.dump(doc, open(dst, "w"), indent=2, sort_keys=True)
open(dst, "a").write("\n")
PY

rm -f "$out.tmp"

echo "update.sh: wrote $out" >&2
jq -r '"  minecraft \(.mcVersion), java \(.javaVersion), asset index \(.assetIndexId)",
       "  \(.libraries|length) libraries, \((.libraries|map(.size)|add)/1048576|floor) MiB",
       "  assets \((.assetIndex.totalSize)/1048576|floor) MiB"' "$out" >&2
