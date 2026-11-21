# Nouveautés de Parker

Une section par version. La section de la version publiée devient le début des notes de la release
et le texte affiché dans la fenêtre de mise à jour de l'app.
Écrire des phrases courtes, une par ligne, commençant par « - », sans gras, titres ni liens.

## 2.30
- Nouveau réglage « Qualité vidéo » (Réglages > Capture > Enregistrement vidéo) : Full HD (1080p), QHD (1440p) ou Maximum (4K). Par défaut, 1440p : la vidéo reste nette, le fichier est plus léger et la finalisation du montage bien plus rapide (Mac).

## 2.29
- Finalisation de la vidéo plus rapide : l'encodeur matériel du Mac est réglé pour la vitesse, au débit de l'enregistrement d'origine, et la bulle caméra n'est plus calculée sur toute l'image mais seulement sur sa zone. Caméra masquée : la vidéo est copiée sans réencodage, quasi instantané (Mac).
- Un pourcentage indique l'avancement de la finalisation (Mac).
- Fenêtre de montage : les boutons réagissent dès le premier clic, même quand la fenêtre s'ouvre derrière l'app active. Pendant la finalisation, Copier, Partager et Finder ne sont plus grisés : l'action part dès que la vidéo est prête (Mac).

## 2.28
- Correction (vérifiée par un test automatique) : la caméra apparaît enfin dans la fenêtre de montage et dans la vidéo finale. Le fichier caméra était fermé trop tôt pendant le montage, donc ses images ne pouvaient pas être ajoutées. Les enregistrements faits avec les versions précédentes retrouvent aussi leur caméra (Mac).

## 2.27
- Correction : la caméra disparaissait dans la fenêtre de montage. Ses images sont maintenant calées sur l'horloge de l'ordinateur au lieu de celle de l'enregistrement d'écran, et le montage les retrouve même quand elles étaient décalées (Mac).

## 2.26
- Enregistrement plein écran : avec plusieurs écrans, un bouton écran dans la barre permet de choisir lequel enregistrer. La barre et la bulle caméra se déplacent sur l'écran choisi, et Parker s'en souvient pour la prochaine fois (Mac).
- Barre d'enregistrement (plein écran et zone) : nouvelle tuile « Son de l'ordi » avec un interrupteur On/Off, à côté de Caméra et Micro, pour enregistrer ou non le son de l'ordinateur (Mac).

## 2.25
- Statistiques anonymes : une fois par jour, Parker télécharge un fichier texte vide de la dernière release, compté par GitHub. Rien n'est envoyé, aucun identifiant, aucune capture. Option « Partager des statistiques anonymes » dans les réglages pour le désactiver.

## 2.24
- Les menus déroulants, pop-ups, popovers et infobulles restent ouverts pendant la capture : avant, Parker passait au premier plan au moment de la capture, et macOS fermait alors tout. Les captures de zone, de fenêtre, de défilement et la pipette les gardent à l'écran (Mac).
- Capture de fenêtre : le menu ou le pop-up ouvert au-dessus de la fenêtre est capturé avec elle (Mac).

## 2.23
- Auto-scroll à pas égaux : la page défile d'une distance fixe, Parker attend qu'elle soit immobile (défilement fluide, fondus), prend une image et la place à la distance connue. La comparaison d'images ne sert plus qu'à affiner la position, elle ne peut plus bloquer la capture (Mac).
- Plus d'alerte « Trop rapide » : les pages avec parallaxe, animations ou vidéo dans le hero ne coupent plus la capture (Mac).

## 2.22
- Capture défilante : chaque ligne de la page est prise au dernier moment où elle est visible, comme sur CleanShot X. Les éléments qui apparaissent en fondu au défilement sont capturés une fois affichés, au lieu de rester blancs ou transparents (Mac).
- Les éléments fixes à l'écran (bulle de chat, boutons flottants) ne se répètent plus en bandes tout le long de la capture. Ils n'apparaissent qu'une fois, en bas, comme sur l'écran (Mac).

## 2.21
- Auto-scroll refait sur le modèle de CleanShot X : la page défile en continu par petits pas réguliers, et les images sont raccordées au fur et à mesure. C'est plus rapide et plus fluide, sans les grands sauts qui faisaient perdre le fil (Mac).
- La vitesse s'adapte toute seule : l'auto-scroll accélère quand tout se raccorde bien, ralentit et remonte un peu quand une page charge du contenu en route, puis s'arrête de lui-même en bas de la page (Mac).

## 2.20
- Capture défilante : plus de faux « Trop rapide » sur les pages qui bougent toutes seules (animation, vidéo, carrousel, curseur qui clignote). Ces zones ne bloquent plus le raccord des images.
- Auto-scroll : si la page ne réagit pas au défilement façon trackpad, Parker essaie le défilement façon molette. Si rien ne bouge, il te le dit et te laisse défiler à la main au lieu d'arrêter la capture (Mac).

## 2.19
- Correction : la caméra n'apparaissait pas dans la fenêtre de montage. Elle est de nouveau visible, et les enregistrements faits avec la 2.18 la retrouvent aussi (Mac).
- Montage : coupe au milieu de la vidéo. Place la tête de lecture, clique sur « Couper ici » (⌘B), sélectionne le passage dans la bande puis « Supprimer le passage » (ou Suppr). Les coupes se déplacent à la souris pour réajuster, et un passage supprimé peut être remis (Mac).

## 2.18
- Fenêtre de montage à la fin de chaque enregistrement d'écran : lecture, coupe du début et de la fin avec les poignées jaunes, puis Copier, Partager, Finder ou Enregistrer (Mac).
- La bulle caméra est maintenant enregistrée à part : dans la fenêtre de montage, glisse-la pour la déplacer, change sa taille ou masque-la, même après l'enregistrement (Mac).

## 2.17
- Enregistrement d'écran : après avoir choisi la zone, une nouvelle barre affiche un gros bouton Démarrer, une tuile Caméra et une tuile Micro avec un interrupteur On/Off. La bulle sert d'aperçu caméra, la tuile Micro se remplit quand il t'entend, et un clic sur une tuile permet de changer d'appareil. Le bouton haut-parleur active ou coupe le son du Mac (Mac).
- Le micro est enfin enregistré dans la vidéo, mélangé au son du Mac sur une seule piste, lisible partout (Mac, macOS 15 ou plus récent).

## 2.16
- Éditeur : la suite de lettres en bas à droite est remplacée par une aide claire. Survole un outil pour voir sa touche de raccourci, ou survole l'aide pour la liste complète (Mac).

## 2.15
- La vignette flottante en bas de l'écran s'attrape partout, même sur ses boutons : glisse-la dans une conversation, un mail, Figma ou le Finder (Mac).

## 2.14
- Correction : une capture pouvait faire changer de bureau (Spaces) et laisser l'écran bloqué entre deux bureaux. Parker ne change plus jamais de bureau pendant une capture (Mac).

## 2.13
- Historique : la fenêtre apparaît en bas de l'écran principal en glissant vers le haut, et la molette ou le trackpad fait défiler les captures (Mac).

## 2.12
- Nouvelle fenêtre d'historique (Maj + touche du profil + H) : la capture sélectionnée en grand avec son app, sa date, son format et sa taille, les boutons Ouvrir, Copier et Partager, et la pellicule des 20 dernières captures (Mac).

## 2.11
- Avec la bulle caméra, l'enregistrement ne démarre plus tout seul : place ta caméra, puis clique sur Démarrer (ou Entrée).
- Capture défilante : l'auto-scroll ne ramène plus la souris au centre. Sortir la souris de la zone met l'auto-scroll en pause, il reprend quand elle revient.

## 2.10
- Bulle caméra dans les enregistrements d'écran : ta webcam dans un rond, que tu peux déplacer et agrandir (double-clic). Bouton caméra ou touche C pendant l'enregistrement (Mac).

## 2.9
- La fenêtre de mise à jour affiche enfin la liste des nouveautés, lisible, au lieu du texte brut de la page de téléchargement.

## 2.8
- Les captures ne sont plus enregistrées sur le bureau par défaut : elles vont dans le presse-papiers et l'historique (20 dernières).
- Nouvelle option « Enregistrer dans un dossier » dans les réglages, pour garder chaque capture en fichier.
- Clic droit dans l'historique : « Enregistrer sous… » (Mac).

## 2.7
- Enregistrer une zone : le voile et le cadre sont bien placés sur un écran secondaire, par exemple un ultra-wide (Mac).
- Capture défilante : l'auto-scroll attend que la page ait fini de bouger et se rattrape tout seul s'il va trop loin.

## 2.6
- Historique des 20 dernières captures avec Maj + touche du profil + H (Mac).
- Avec le profil Cmd+Shift, les raccourcis de capture d'Apple sont coupés tant que Parker tourne (Mac).

## 2.5
- Fichiers de téléchargement renommés : un installeur par système, les fichiers .zip servent à la mise à jour automatique.
