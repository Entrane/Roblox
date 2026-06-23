# `place/` — Sauvegarde versionnée de la map

Ce dossier conserve un **export XML de `Workspace.Map`** comme filet de sécurité :
si Studio plante, la map (construite à la main) n'est pas perdue.

## Pourquoi ce dossier existe

Le **code** du jeu est déjà versionné via Rojo (`src/`). En revanche
`Workspace.Map` — les objets 3D placés à la main (`FuseSpots/FuseSpot1..5`,
`Generator`, `ExitBarrier`, `ExitZone`, `SpawnPoint`, sol, décor…) — **n'est PAS
synchronisé par Rojo**. C'est le seul contenu irremplaçable hors Git, donc on en
garde une copie ici.

> La place complète se reconstruit toujours = **Rojo (code) + `place/Map.rbxmx` (map)**.

## Convention

- **Format : XML** (`.rbxmx`), pas binaire — Git compresse/diff mieux, pas besoin
  de Git LFS.
- **Un seul fichier suivi : `place/Map.rbxmx`.** Le `.gitignore` ignore tous les
  `*.rbxmx` par défaut (artefacts de build Rojo) **sauf** celui-ci, via
  l'exception `!place/Map.rbxmx`.
- On ne versionne **pas** le `.rbxl` binaire complet (gonflement de l'historique).

## Comment sauvegarder la map (côté Studio)

1. Dans l'Explorer, **clic droit sur `Workspace.Map`** → **Save to File…**
2. Choisir le **format XML** et enregistrer sous **`place/Map.rbxmx`** (à la racine
   de ce clone du repo).
3. Puis, en ligne de commande :
   ```sh
   git add place/Map.rbxmx
   git commit -m "Sauvegarde map (Workspace.Map)"
   git push
   ```

## Comment restaurer la map

1. Studio → **Insert From File…** → sélectionner `place/Map.rbxmx`.
2. L'objet `Map` réapparaît dans le Workspace ; le repositionner si besoin.

## ⚠️ Vérifier après restauration

Les noms doivent rester EXACTS (voir `STUDIO_SETUP.md`) pour que les Services les
trouvent : `Map.FuseSpots.FuseSpot1..5`, `Map.Generator`, `Map.ExitBarrier`,
`Map.ExitZone`, `Map.SpawnPoint`.
