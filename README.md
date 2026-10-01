# Parker

Outil de capture d'écran natif macOS, dans l'esprit de CleanShot X. Basé sur le projet open source [ScreenCap](https://github.com/8tp/ScreenCap) (licence MIT), retravaillé sur trois points : la capture défilante, l'éditeur d'annotations et les vignettes flottantes en bas à gauche.

## Installation (5 minutes)

**Prérequis :** macOS 14 (Sonoma) ou plus récent, et les outils développeur Apple.

1. Ouvre le Terminal et installe les outils Apple si ce n'est pas déjà fait :
   ```bash
   xcode-select --install
   ```
2. Dézippe le dossier, place-toi dedans, puis lance :
   ```bash
   cd ~/Downloads/Parker
   ./build-app.sh
   ```
   Le script compile, crée `Parker.app`, l'installe dans `/Applications` et la lance. L'icône apparaît dans la barre des menus.
3. Au premier lancement, autorise Parker dans **Réglages Système > Confidentialité et sécurité** :
   * **Enregistrement de l'écran** : obligatoire pour capturer.
   * **Accessibilité** : pour l'auto-scroll de la capture défilante et la touche Esc pendant le scroll.

   Après avoir coché les cases, quitte puis relance Parker.

> **Astuce (évite de redonner les autorisations à chaque recompilation)**
> Lance une fois `./scripts/setup-signing.sh` (voir plus bas). Le script de build utilise ensuite automatiquement ce certificat.

## Version Windows

Parker existe aussi pour **Windows 10 (version 2004 ou plus récente) et Windows 11**. Chaque release contient `Parker-Windows.zip`.

* **Installation :** télécharger `Parker-Windows.zip` sur [la page des releases](https://github.com/Sholypro/parker/releases/latest), dézipper, ranger `Parker.exe` où tu veux (par exemple `Documents\Parker`) et le lancer. Aucune autorisation à donner.
* **Premier lancement :** Windows SmartScreen peut afficher « Windows a protégé votre ordinateur » (l'app n'est pas signée par un éditeur payant). Cliquer sur **Informations complémentaires**, puis **Exécuter quand même**.
* **Utilisation :** Parker vit dans la zone de notification (à côté de l'horloge, parfois derrière la petite flèche ^). Clic sur l'icône = menu.
* **Raccourcis :** `Ctrl+Maj+4` zone · `Ctrl+Maj+3` écran · `Ctrl+Maj+5` fenêtre · `Ctrl+Maj+6` capture défilante · `Ctrl+Maj+7` épingler la dernière capture.
* **Captures :** enregistrées dans `Images\Parker` (modifiable dans les Réglages), et copiées dans le presse-papiers.
* **Mises à jour :** automatiques, comme sur Mac (menu **Rechercher des mises à jour…**).
* **Code :** dossier `windows/` (C# .NET 8, WinForms), compilé par GitHub à chaque version.

## Partager avec des collègues + mises à jour automatiques

Le dépôt GitHub sert de « serveur de mises à jour » : chaque version publiée est compilée par GitHub, puis l'app de chacun la propose toute seule (au lancement, au plus une fois toutes les 6 h, ou via le menu **Rechercher des mises à jour…**).

### Pour les collègues (installation, une seule fois)
1. Ouvrir [github.com/Sholypro/parker/releases](https://github.com/Sholypro/parker/releases) et télécharger `Parker.zip` de la dernière version.
2. Dézipper et glisser `Parker.app` dans **Applications**.
3. Premier lancement : macOS bloque l'app (elle n'est pas notarisée par Apple). Aller dans **Réglages Système > Confidentialité et sécurité**, tout en bas : **Ouvrir quand même**.
4. Autoriser **Enregistrement de l'écran** et **Accessibilité**, puis relancer l'app.

Ensuite, plus rien à faire : les mises à jour s'installent en un clic, sans repasser par l'étape 3.

### Pour toi (publier une nouvelle version)
```bash
./scripts/release.sh 1.2 "Ce qui change dans cette version"
```
GitHub compile l'app en 5 minutes environ (onglet **Actions** du dépôt), puis publie la release.

### Signature (une fois, sur ton Mac uniquement)
```bash
./scripts/setup-signing.sh
```
Crée le certificat « Parker Local » et prépare 2 secrets à coller dans GitHub (Settings > Secrets and variables > Actions). Sans lui, macOS redemande les autorisations à chaque mise à jour, chez tout le monde.

## Raccourcis globaux (par défaut)

| Raccourci | Action |
|---|---|
| `⌃⇧1` | Barre tout-en-un |
| `⌃⇧3` | Capturer tout l'écran |
| `⌃⇧4` | Capturer une zone |
| `⌃⇧5` | Capturer une fenêtre |
| `⌃⇧6` | **Capture défilante (scroll)** |
| `⌃⇧7` / `⌃⇧8` | Enregistrer l'écran / une zone |
| `⌃⇧9` | Extraire le texte (OCR) |
| `⌃⇧0` | Pipette couleur |

Le profil `⌘⇧` (comme macOS) est disponible dans les Réglages. Désactive alors les raccourcis de capture d'Apple pour éviter les doublons.

## Ce qui a été ajouté ou refait

### 1. Capture défilante (moteur réécrit)
* Sélectionne une zone, puis **fais défiler toi-même** (capture ~7 images/s, assemblage en direct) ou clique sur **Auto** : l'app fait défiler jusqu'en bas de la page et termine toute seule.
* **Aperçu live** à côté de la zone, avec la hauteur en pixels.
* Gère les **en-têtes et pieds de page fixes** (barres de navigation, bandeaux cookies) : ils n'apparaissent qu'une fois, au bon endroit.
* Ignore la barre de défilement macOS qui apparaît pendant le scroll.
* Si tu défiles trop vite, rien n'est perdu : un message te demande de remonter un peu et la capture reprend.
* `Entrée` = terminer, `Esc` = annuler. Limite de sécurité : 40 000 px de haut.

### 2. Vignettes flottantes (Quick Access Overlay)
* **En bas à gauche par défaut**, empilées : la plus récente en bas, les anciennes remontent (6 max).
* Au survol : **Copier** et **Annoter** au centre, + Fermer, Épingler, Afficher dans le Finder, Supprimer dans les coins.
* Clic = ouvre l'annotation. **Glisser** la vignette = dépose le fichier dans n'importe quelle app (Slack, Figma, Mail…), la vignette disparaît ensuite.
* Clic droit : menu complet (Enregistrer sous…, Tout fermer…). Swipe horizontal à deux doigts = fermer.
* Les captures longues affichent leur partie haute au lieu d'une miniature illisible.
* Survol = le minuteur de fermeture se met en pause. Position et durée réglables dans les Réglages.

### 3. Éditeur d'annotations
* Outils : sélection, flèche (effilée façon CleanShot), rectangle, ellipse, ligne, texte, crayon, surligneur, **compteur**, **flou** (gaussien), **pixellisation**, **spotlight** (assombrit tout sauf la zone), recadrage.
* **Raccourcis une touche** : `V` sélection, `A` flèche, `R` rectangle, `O` ellipse, `L` ligne, `T` texte, `P` crayon, `H` surligneur, `N` compteur, `B` flou, `X` pixellisation, `S` spotlight, `C` recadrer.
* **Poignées de redimensionnement** sur la sélection (coins des formes, extrémités des flèches). `Shift` = angles à 45° ou formes carrées.
* Changer la couleur ou l'épaisseur s'applique aussi à l'élément sélectionné.
* Texte : la taille suit l'épaisseur ; le bouton **Remplissage** transforme le texte en étiquette colorée. Double-clic pour modifier un texte.
* `⌘Z` / `⇧⌘Z`, `⌘C` copier, `⌘S` enregistrer, `⇧⌘S` enregistrer sous, `⌘D` dupliquer, `⌘A` tout sélectionner, flèches du clavier pour déplacer (`Shift` = 10 px), `Suppr` pour effacer, `Entrée` pour valider un recadrage.
* Les captures défilantes s'ouvrent à une taille lisible et défilent dans l'éditeur (avant : réduites à quelques pixels de large).
* Export en pleine résolution Retina, sans les contours de sélection.

### Déjà présent dans Parker
Capture plein écran / zone / fenêtre, retardateur, masquage des icônes du bureau, enregistrement vidéo + export GIF, OCR, pipette, épinglage à l'écran, fonds et mise en valeur (beautify), historique des captures récentes.

## Limites connues
* Le code n'a pas pu être compilé dans l'environnement où il a été écrit (pas de Mac). Si `./build-app.sh` affiche une erreur, copie-la telle quelle : la correction est en général immédiate.
* L'auto-scroll envoie de vrais événements de défilement à la fenêtre sous le curseur : ne bouge pas la souris hors de la zone pendant l'auto-scroll.
* Les contenus animés (vidéos, carrousels automatiques) peuvent perturber l'assemblage, comme sur CleanShot.

## Crédits et licence
Base : [8tp/ScreenCap](https://github.com/8tp/ScreenCap), licence MIT (voir `LICENSE`). Modifications : capture défilante, vignettes, éditeur, localisation française, script de build.
