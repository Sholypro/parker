# Bibliothèques intégrées

`ThinkingOrbsKit` et `BorderBeamKit` sont les portages SwiftUI de [libraries.dev](https://libraries.dev)
(licence MIT, voir `LICENSE.txt`), copiés depuis https://github.com/Jakubantalik/Libraries.dev
(commit bfcb863, 15/10/2026).

Modifications pour Parker :
- `BorderBeamKit/BeamSpecData.swift` : `beam-spec.json` intégré au code (pas de bundle de ressources SwiftPM,
  qui casserait la signature de l'app).
- `BorderBeamKit/BeamShaderLoader.swift` : les shaders Metal (`../Shaders/BeamShaders.metal`) sont compilés
  par `build-app.sh` dans `Parker.app/Contents/Resources/BorderBeam.metallib` et chargés depuis là.
- `ThinkingOrbsKit/Snapshot.swift` retiré (outil de test).
