#!/bin/bash
# Publie une nouvelle version pour toi et tes collègues.
# Usage : ./scripts/release.sh 1.2 "Ajout de la loupe, vignettes plus grandes"
# GitHub compile l'app (~5 min) puis l'app de chacun propose la mise à jour.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-Nouvelle version}"
if [[ -z "$VERSION" ]]; then
  echo "Usage : ./scripts/release.sh <version> \"<notes>\"   (ex. ./scripts/release.sh 1.2 \"Loupe\")"
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "→ Enregistrement des modifications en cours…"
  git add -A
  git commit -m "Version $VERSION : $NOTES"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Parker/Support/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Parker/Support/Info.plist 2>/dev/null || true
if [[ -n "$(git status --porcelain)" ]]; then
  git commit -am "Version $VERSION"
fi
git push
git tag -a "v$VERSION" -m "$NOTES"
git push origin "v$VERSION"
echo "✓ Version $VERSION envoyée. Suis la compilation dans l'onglet Actions du dépôt GitHub."
