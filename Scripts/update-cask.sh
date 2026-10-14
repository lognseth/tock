#!/bin/bash
# Renders the Homebrew cask for a release DMG and writes it to <output-file>.
# Usage: Scripts/update-cask.sh <dmg> <version> <output-file>
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="$1"; VERSION="$2"; OUT="$3"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
mkdir -p "$(dirname "$OUT")"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" Scripts/tock.rb.template > "$OUT"
echo "Wrote $OUT (sha256 $SHA)"
