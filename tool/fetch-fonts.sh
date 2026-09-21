#!/bin/sh
# Downloads Mull's three typefaces from Fontshare into assets/fonts/.
#
#   ./tool/fetch-fonts.sh
#
# Chillax, Excon and Ranade are by the Indian Type Foundry, free under the
# ITF Free Font License. That license lets Mull embed them in the app, but not
# make the font files available through a public repository, so they are not
# in git: each person building Mull gets their own copy from Fontshare, as the
# license asks. The build scripts run this when the fonts are missing.
#
# Checksums pin the exact files the app was designed with, so an update
# upstream cannot quietly change how Mull looks.

set -e
cd "$(dirname "$0")/.."
DEST=assets/fonts
mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() { # family, then the files wanted from it
  family=$1; shift
  lower=$(echo "$family" | tr '[:upper:]' '[:lower:]')
  curl -sfL -o "$TMP/$lower.zip" "https://api.fontshare.com/v2/fonts/download/$lower"
  for file in "$@"; do
    unzip -p "$TMP/$lower.zip" "${family}_Complete/Fonts/OTF/$file" > "$DEST/$file"
  done
}

fetch Chillax Chillax-Medium.otf Chillax-Semibold.otf
fetch Excon Excon-Light.otf Excon-Regular.otf Excon-Medium.otf
fetch Ranade Ranade-Light.otf Ranade-Regular.otf Ranade-Medium.otf

cd "$DEST"
shasum -c --quiet <<'SUMS'
5296bf828bfb7cae636892b1cee9ee7ddeb8d5aa  Chillax-Medium.otf
11d9fffe8e50bc271bc9a2df02325afd74482759  Chillax-Semibold.otf
2fba38c61518854d10627f480b6a45bacf7cad93  Excon-Light.otf
f6c284eb8e4cd28fb841d0eff2147adfffbf6d3d  Excon-Medium.otf
cc0cbe53dbd6d3907e246c69782e28f2b036ad97  Excon-Regular.otf
7faf9b8eb7c9f8b04d32df464828778558c1003c  Ranade-Light.otf
5099c78887a3bb4626d713ee1ffd43c26b523f3d  Ranade-Medium.otf
1a22471e5981cdffab94ed45f3e517549d2c6a51  Ranade-Regular.otf
SUMS
echo "Fonts ready in assets/fonts."
