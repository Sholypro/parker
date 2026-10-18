#!/bin/bash
# Installe (ou met à jour) Parker sur Mac depuis la dernière version publiée sur GitHub.
# Usage : curl -fsSL https://raw.githubusercontent.com/Sholypro/parker/main/install.sh | bash
set -euo pipefail

REPO="Sholypro/parker"
URL="https://github.com/${REPO}/releases/latest/download/Parker-Mac.zip"
TARGET="/Applications/Parker.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Ce script est pour Mac. Sur Windows, télécharge Parker-Windows-Installer.exe : https://github.com/${REPO}/releases/latest"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Téléchargement de Parker…"
curl -fL --progress-bar -o "${WORK}/Parker-Mac.zip" "$URL"
/usr/bin/ditto -x -k "${WORK}/Parker-Mac.zip" "$WORK"
if [[ ! -d "${WORK}/Parker.app" ]]; then
  echo "Archive inattendue : Parker.app introuvable."
  exit 1
fi

# Ferme la version en cours avant de la remplacer
if pgrep -xq Parker; then
  osascript -e 'quit app "Parker"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Parker >/dev/null 2>&1 || true
fi

echo "Installation dans Applications…"
rm -rf "$TARGET"
/usr/bin/ditto "${WORK}/Parker.app" "$TARGET"
/usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

VERSION="$(/usr/bin/defaults read "${TARGET}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo "Parker ${VERSION} est installé. Lancement…"
open "$TARGET"
