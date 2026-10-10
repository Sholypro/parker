# Signature et alertes de sécurité

## Pourquoi macOS et Windows affichent une alerte

Sans certificat d'éditeur reconnu, le système ne peut pas vérifier qui a publié l'app :

* **Mac** : « Apple n'a pas pu confirmer que « Parker » ne contenait pas de logiciel malveillant ». Il faut cliquer sur **Ouvrir quand même** dans Réglages Système > Confidentialité et sécurité, une seule fois.
* **Windows** : SmartScreen affiche « Windows a protégé votre ordinateur » et « Éditeur inconnu ». Il faut cliquer sur **Informations complémentaires > Exécuter quand même**, une seule fois.

Ce n'est pas un défaut de l'app. Ces alertes disparaissent uniquement avec un certificat payant. La publication automatique est déjà prête : il suffit d'ajouter les secrets ci-dessous dans GitHub (Settings > Secrets and variables > Actions), puis de publier une version.

## Mac : compte Apple Developer + notarisation (supprime l'alerte)

Coût : abonnement Apple Developer Program, 99 $ par an (tarif affiché par Apple, à vérifier au moment de l'inscription).

1. S'inscrire sur https://developer.apple.com/programs/ (compte individuel possible).
2. Dans Xcode > Réglages > Comptes, ou sur developer.apple.com > Certificates, créer un certificat **Developer ID Application**.
3. Dans Trousseaux d'accès, exporter ce certificat avec sa clé privée en `.p12` (choisir un mot de passe).
4. Créer un **mot de passe pour app** sur https://account.apple.com (section Connexion et sécurité).
5. Ajouter ces secrets dans GitHub :

| Secret | Valeur |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | le .p12 encodé : `base64 -i certificat.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | le mot de passe du .p12 |
| `APPLE_ID` | l'adresse e-mail du compte Apple Developer |
| `APPLE_TEAM_ID` | l'identifiant d'équipe (10 caractères, page Membership) |
| `APPLE_APP_PASSWORD` | le mot de passe pour app de l'étape 4 |

À la version suivante, GitHub signe Parker avec le Developer ID (runtime renforcé), le fait notariser par Apple et agrafe le ticket sur l'app et sur le .dmg. Plus aucune alerte au premier lancement.

À savoir : en passant du certificat « Parker Local » au Developer ID, macOS considère Parker comme une nouvelle app une seule fois. Chacun devra réautoriser **Enregistrement de l'écran** et **Accessibilité** après cette mise à jour-là.

## Windows : certificat de signature de code (affiche l'éditeur)

Deux options, à comparer au moment de l'achat (prix et conditions changent souvent) :

* **Azure Artifact Signing** (ex Trusted Signing, Microsoft) : abonnement mensuel. La disponibilité pour les particuliers dépend du pays : à vérifier pour la France.
* **Certificat de signature de code (OV)** d'une autorité de certification (DigiCert, Sectigo, Certum…) : abonnement annuel. Depuis 2023, la clé est livrée sur un support matériel ou dans un HSM cloud, ce qui demande d'adapter l'étape de signature.

Le workflow sait déjà signer avec un certificat `.pfx` exportable :

| Secret | Valeur |
|---|---|
| `WINDOWS_PFX_BASE64` | le .pfx encodé en base64 |
| `WINDOWS_PFX_PASSWORD` | son mot de passe |

Même signé, un nouvel exécutable peut encore déclencher SmartScreen pendant quelques semaines, le temps qu'il gagne en réputation. L'éditeur affiché devient toutefois « Sholy Design » au lieu de « Éditeur inconnu ».
