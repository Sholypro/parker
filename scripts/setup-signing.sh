#!/bin/bash
# Crée le certificat de signature "Parker Local" (gratuit, valable 10 ans).
#
# Pourquoi : macOS rattache les autorisations (Enregistrement de l'écran, Accessibilité) à la
# signature de l'app. Avec une signature stable, elles restent valides après chaque mise à jour.
#
# À lancer UNE SEULE FOIS, sur ton Mac uniquement (pas sur ceux des collègues) :
#   ./scripts/setup-signing.sh
#
# Le script :
#   1. crée le certificat et l'ajoute à ton trousseau (les builds locaux l'utilisent) ;
#   2. prépare les deux secrets à coller dans GitHub (les builds de release l'utilisent).
set -euo pipefail

NAME="Parker Local"
OUT="$HOME/Documents/Parker-signature"
OPENSSL=/usr/bin/openssl   # LibreSSL d'Apple : format .p12 compatible avec le trousseau

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Le certificat \"$NAME\" existe déjà dans ton trousseau. Rien à faire."
  echo "(Les secrets GitHub ont été enregistrés dans $OUT lors de la première exécution.)"
  exit 0
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "→ Création du certificat…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cfg" 2>/dev/null

PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$OUT/ParkerLocal.p12" -passout "pass:$PASS"

echo "→ Ajout au trousseau (session)…"
security import "$OUT/ParkerLocal.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign >/dev/null

base64 -i "$OUT/ParkerLocal.p12" > "$OUT/SIGNING_P12_BASE64.txt"
printf "%s" "$PASS" > "$OUT/SIGNING_P12_PASSWORD.txt"
chmod 600 "$OUT"/*

cat <<EOF

✓ Certificat créé. Les prochains ./build-app.sh l'utiliseront automatiquement.

Pour les versions publiées sur GitHub, ajoute 2 secrets au dépôt :
  GitHub > ton dépôt > Settings > Secrets and variables > Actions > New repository secret

  1. Nom : SIGNING_P12_BASE64     Valeur : contenu du fichier $OUT/SIGNING_P12_BASE64.txt
  2. Nom : SIGNING_P12_PASSWORD   Valeur : contenu du fichier $OUT/SIGNING_P12_PASSWORD.txt

Astuce : "pbcopy < $OUT/SIGNING_P12_BASE64.txt" copie la valeur dans le presse-papiers.

⚠ Ces fichiers permettent de signer une app "Parker" : ne les partage avec personne et ne
  les ajoute jamais au dépôt. Garde une copie (ex. dans ton gestionnaire de mots de passe).
EOF
