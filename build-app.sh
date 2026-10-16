#!/bin/bash
# Construit Parker.app, la signe et l'installe dans /Applications.
# Usage :  ./build-app.sh                 build + install + lancement
#          ./build-app.sh --no-install    build seul (dist/Parker.app), utilisé par GitHub
# Variables optionnelles : SC_VERSION=1.3 (numéro de version), SC_SIGN_IDENTITY=<hash SHA-1>,
#   SC_HARDENED=1 (runtime renforcé + horodatage, obligatoire pour la notarisation Apple)
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

# Shaders Metal de l'effet « border beam » (libraries.dev). SwiftPM ne compile pas les .metal :
# on les compile ici quand le compilateur Metal est là (Xcode complet, comme sur GitHub).
# Sans lui, Parker fonctionne et affiche une bordure simple à la place de l'effet.
# PARKER_REQUIRE_SHADERS=1 (publication) : échec si la compilation est impossible.
REQUIRE_SHADERS="${PARKER_REQUIRE_SHADERS:-0}"
METALLIB="$APP/Contents/Resources/BorderBeam.metallib"
if xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  echo "→ Compilation des shaders Metal…"
  # `xcrun -f metal` peut réussir alors que la compilation échoue (ex. Xcode 26 sans la
  # « Metal Toolchain » installée) : on teste chaque étape au lieu de laisser `set -e` tout arrêter.
  SHADER_TMP="$(mktemp -d -t parker-shaders)"
  AIR="$SHADER_TMP/BeamShaders.air"
  if xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c "$PKG/Shaders/BeamShaders.metal" -o "$AIR" \
     && xcrun -sdk macosx metallib "$AIR" -o "$METALLIB"; then
    echo "→ Shaders Metal compilés."
  else
    rm -f "$METALLIB"
    if [[ "$REQUIRE_SHADERS" == "1" ]]; then
      rm -rf "$SHADER_TMP"
      echo "→ Échec de la compilation des shaders Metal (PARKER_REQUIRE_SHADERS=1) : build interrompu."
      echo "  Vérifie que la Metal Toolchain est installée : xcodebuild -downloadComponent MetalToolchain"
      exit 1
    fi
    echo "→ Échec de la compilation des shaders Metal (Metal Toolchain manquante ?) :"
    echo "  l'app est construite sans metallib, l'effet « border beam » est remplacé par une bordure simple."
  fi
  rm -rf "$SHADER_TMP"
elif [[ "$REQUIRE_SHADERS" == "1" ]]; then
  echo "→ Compilateur Metal introuvable (PARKER_REQUIRE_SHADERS=1) : impossible de compiler les shaders."
  exit 1
else
  echo "→ Compilateur Metal absent (Xcode non installé) : effet « border beam » remplacé par une bordure simple."
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
  echo "→ Signature avec le certificat ${IDENTITY}…"
else
  IDENTITY="-"
  echo "→ Signature ad hoc (lance ./scripts/setup-signing.sh pour garder les autorisations entre les versions)…"
fi
if [[ "${SC_HARDENED:-0}" == "1" && "$IDENTITY" != "-" ]]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

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
