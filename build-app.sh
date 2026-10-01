#!/bin/bash
# Construit Parker.app, la signe et l'installe dans /Applications.
# Usage :  ./build-app.sh                 build + install + lancement
#          ./build-app.sh --no-install    build seul (dist/Parker.app), utilisé par GitHub
# Variables optionnelles : SC_VERSION=1.3 (numéro de version), SC_SIGN_IDENTITY=<hash SHA-1>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/Parker"
DIST="$ROOT/dist"
APP="$DIST/Parker.app"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

if ! xcode-select -p >/dev/null 2>&1; then
  echo "→ Outils de développement Apple absents. Lance : xcode-select --install"
  exit 1
fi

echo "→ Compilation (release)…"
cd "$PKG"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "→ Assemblage de l'app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Parker" "$APP/Contents/MacOS/Parker"
cp "$PKG/Support/Info.plist" "$APP/Contents/Info.plist"

if [[ -n "${SC_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SC_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SC_VERSION" "$APP/Contents/Info.plist"
fi

if [[ -d "$PKG/Support/AppIcon.iconset" ]]; then
  iconutil -c icns "$PKG/Support/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Signature : certificat "Parker Local" (créé par ./scripts/setup-signing.sh) pour que macOS
# garde les autorisations d'une version à l'autre. Sinon, signature ad hoc.
IDENTITY="${SC_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | grep '"Parker Local"' | head -1 | awk '{print $2}' || true)"
fi
if [[ -n "$IDENTITY" ]]; then
  echo "→ Signature avec le certificat Parker Local…"
else
  IDENTITY="-"
  echo "→ Signature ad hoc (lance ./scripts/setup-signing.sh pour garder les autorisations entre les versions)…"
fi
codesign --force --deep --sign "$IDENTITY" "$APP"

if [[ $INSTALL -eq 1 ]]; then
  echo "→ Installation dans /Applications…"
  pkill -x Parker 2>/dev/null || true
  # Ancien nom de l'app : on retire l'ancienne version pour éviter d'avoir les deux
  pkill -x ScreenCap 2>/dev/null || true
  rm -rf "/Applications/ScreenCap.app"
  sleep 0.5
  rm -rf "/Applications/Parker.app"
  ditto "$APP" "/Applications/Parker.app"
  rm -rf "$DIST"   # évite un doublon dans Spotlight
  open "/Applications/Parker.app"
  echo "✓ Parker est lancé (icône dans la barre des menus)."
else
  echo "✓ App prête : $APP"
fi
