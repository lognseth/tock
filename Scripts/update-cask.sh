#!/bin/bash
# Renders the Homebrew cask for a release DMG and writes it to <output-file>.
# Usage: Scripts/update-cask.sh <dmg> <version> <output-file>
set -euo pipefail

# Resolve paths before changing directory, so relative arguments mean what the caller expects.
DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; VERSION="$2"
mkdir -p "$(dirname "$3")"
OUT="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
cd "$(dirname "$0")/.."
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" Scripts/tock.rb.template > "$OUT"
echo "Wrote $OUT (sha256 $SHA)"
