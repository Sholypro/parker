#!/bin/bash
# Publie une nouvelle version pour toi et tes collègues.
# Usage : ./scripts/release.sh 1.2 "Ajout de la loupe, vignettes plus grandes"
# Il suffit de changer le numéro de version et de pousser sur main : GitHub compile
# l'app (~5 min) puis l'app de chacun propose la mise à jour.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-Nouvelle version}"
if [[ -z "$VERSION" ]]; then
  echo "Usage : ./scripts/release.sh <version> \"<notes>\"   (ex. ./scripts/release.sh 1.2 \"Loupe\")"
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Parker/Support/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Parker/Support/Info.plist
git add -A
git commit -m "Version $VERSION : $NOTES"
git push
echo "✓ Version $VERSION envoyée. Suis la compilation dans l'onglet Actions du dépôt GitHub."
