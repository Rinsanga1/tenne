#!/usr/bin/env bash
#
# Mint one licence key.
#
#   ./mintkey.sh "Iron Temple Gym"              # purchased today
#   ./mintkey.sh "Iron Temple Gym" 2026-09-21   # purchased on a given day
#
# The key is a base32 blob: a payload (format byte, purchase date, licensee
# name) followed by an ECDSA P-256 signature over that payload. The exe holds
# only the public key, so this script -- and license-private.pem -- are the
# only things in the world that can produce a key that tenne.exe accepts.
#
# KEEP license-private.pem OFF THE BUILD MACHINE AND OUT OF ANY REPOSITORY.
# Lose it and every future key has to be re-issued under a new public key;
# leak it and anyone can mint their own.
set -euo pipefail

KEYFILE="${KEYFILE:-license-private.pem}"
NAME="${1:-}"
DATE="${2:-$(date +%F)}"

[ -n "$NAME" ] || { echo "usage: ./mintkey.sh \"Licensee name\" [YYYY-MM-DD]" >&2; exit 2; }
[ -f "$KEYFILE" ] || { echo "no $KEYFILE -- see the header of this script" >&2; exit 2; }
# the name lives in the key and is shown in the app; 48 bytes keeps the key sane
[ "${#NAME}" -le 48 ] || { echo "licensee name over 48 characters" >&2; exit 2; }

days=$(( ( $(date -d "$DATE" +%s) - $(date -d 2020-01-01 +%s) ) / 86400 ))
[ "$days" -ge 0 ] && [ "$days" -lt 16777216 ] || { echo "date out of range" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '\x01' > "$tmp/payload"
printf "\\x$(printf %02x $((days >> 16 & 255)))\\x$(printf %02x $((days >> 8 & 255)))\\x$(printf %02x $((days & 255)))" >> "$tmp/payload"
printf '%s' "$NAME" >> "$tmp/payload"

openssl pkeyutl -sign -inkey "$KEYFILE" -rawin -digest sha256 \
                -in "$tmp/payload" -out "$tmp/sig.der"

# BCryptVerifySignature wants the raw r||s pair, 32 bytes each; OpenSSL emits
# a DER SEQUENCE of two minimally-encoded INTEGERs, so re-pad them by hand.
raw=""
for h in $(openssl asn1parse -inform DER -in "$tmp/sig.der" | sed -n 's/.*INTEGER *://p'); do
  [ "${#h}" -eq 66 ] && h="${h#00}"          # drop DER's sign byte
  while [ "${#h}" -lt 64 ]; do h="0$h"; done
  raw="$raw$h"
done
[ "${#raw}" -eq 128 ] || { echo "signature came out ${#raw} hex chars, expected 128" >&2; exit 1; }

printf '%s' "$raw" | xxd -r -p >> "$tmp/payload"

echo "Licensed to : $NAME"
echo "Purchased   : $DATE"
echo "Key         :"
base32 < "$tmp/payload" | tr -d '=\n' | sed -e 's/.\{8\}/&-/g' -e 's/-$//'
