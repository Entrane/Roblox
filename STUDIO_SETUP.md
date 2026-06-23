# Checklist Studio — « Signal Lost » serveur en conditions réelles

> **État du code de référence :** checklist alignée sur la branche
> `claude/friendly-shannon-6xpcs6` (boucle PvP + client HUD + map générée par
> script). Si le code évolue, revérifier les noms d'objets / valeurs ci-dessous
> contre les Services.

Objectif : pouvoir ouvrir Studio, cocher chaque item, et faire **tourner la
boucle serveur PvP** (lobby → rôles → manche → fusibles → sortie → évasion/mort
→ résolution → intermission), désormais avec le **client (HUD, écholocation,
sprint/torche/revive, capacités Écho)** en place.

---

## 0. Pré-requis (avant de toucher la map)

- [ ] Rojo sync actif (`rojo serve` + plugin connecté) → `src/` peuplé dans
      ReplicatedStorage / ServerStorage / ServerScriptService / StarterPlayer.
- [ ] **`Workspace.Map` n'est PAS synchronisé par Rojo** (absent de
      `default.project.json`) → elle se construit **via le script de génération**.
- [ ] **Générer la map** : ouvrir `View > Command Bar`, coller **tout**
      `place/build_map.lua` et exécuter. Le script **détruit l'ancienne
      `Workspace.Map`** puis reconstruit sol, plafond fermé, 9 salles, couloirs
      et tous les objets fonctionnels (noms exacts) ; il configure aussi le
      `Lighting` (ambiance bunker de nuit). Idempotent : relançable à volonté.
- [ ] Après génération, **sauver la map** : clic droit `Workspace.Map`
      `> Save to File...` → `place/Map.rbxm` (le binaire est versionné à part —
      Rojo ne le synchronise pas).
- [ ] Le sol (`Map.Floor`, 140×140) et le plafond (`Map.Ceiling`) sont créés par
      le script ; pas de baseplate manuelle à ajouter. `CharacterAutoLoads` est
      forcé à `false` par le code (spawns via `LoadCharacter` + téléport).

---

## 1. Layout de la map — grille 3×3 « bunker laboratoire »

Le script `place/build_map.lua` place 9 salles (intérieur 30×30, centres espacés
de 48 studs) reliées par des couloirs de 10 studs (adjacence de grille → boucles,
≥ 2 chemins, pas d'impasse). Plafond fermé (ambiance bunker). **Le Sas (SE) n'a
qu'une entrée**, gardée par l'`ExitBarrier`.

| Salle | Position (col,row) | Centre monde (X,Z) | Accent | Objet fonctionnel |
|---|---|---|---|---|
| Sécurité (NO) | (-1,-1) | (-48,-48) | rouge | `FuseSpots.FuseSpot5` |
| Laboratoire (N) | (0,-1) | (0,-48) | cyan | `FuseSpots.FuseSpot1` |
| Stockage (NE) | (1,-1) | (48,-48) | orange | `FuseSpots.FuseSpot2` |
| Communications (O) | (-1,0) | (-48,0) | violet | `FuseSpots.FuseSpot4` |
| **Hub** (C) | (0,0) | (0,0) | gris-bleu | `SpawnPoint` |
| Médical (E) | (1,0) | (48,0) | vert | `FuseSpots.FuseSpot3` |
| Maintenance (SO) | (-1,1) | (-48,48) | sombre | *(cachette, 2 couloirs)* |
| Réacteur (S) | (0,1) | (0,48) | jaune | `Generator` |
| Sas de sortie (SE) | (1,1) | (48,48) | lime | `ExitBarrier` + `ExitZone` |

### Objets fonctionnels (noms EXACTS, sensibles à la casse — créés par le script)

| Chemin exact | Type | Propriétés clés | Position (X,Y,Z) | Utilisé par |
|---|---|---|---|---|
| `Map.SpawnPoint` | **BasePart** | `Anchored=true` | (0, 0.5, 0) Hub | RoundService (téléport début de phase, offset +Y) |
| `Map.FuseSpots` | **Folder** | conteneur des 5 spots | — | FuseService |
| `Map.FuseSpots.FuseSpot1` | **BasePart** | `Anchored=true` | (0,0.5,-48) Labo | FuseService (fusible à +3 Y) |
| `Map.FuseSpots.FuseSpot2` | **BasePart** | `Anchored=true` | (48,0.5,-48) Stockage | idem |
| `Map.FuseSpots.FuseSpot3` | **BasePart** | `Anchored=true` | (48,0.5,0) Médical | idem |
| `Map.FuseSpots.FuseSpot4` | **BasePart** | `Anchored=true` | (-48,0.5,0) Comms | idem |
| `Map.FuseSpots.FuseSpot5` | **BasePart** | `Anchored=true` | (-48,0.5,-48) Sécurité | idem |
| `Map.Generator` | **BasePart** (⚠️ PAS un Model) | `Anchored`, `CanCollide=true` | (0,3,48) Réacteur | FuseService (prompt dépôt ; fusible à +4 Y) |
| `Map.ExitBarrier` | **BasePart** | `Anchored`, **`CanCollide=true`**, `Transparency=0` | (33,9,48) porte ouest du Sas | FuseService (au 5/5 → `CanCollide=false` + `Transparency=0.7`) |
| `Map.ExitZone` | **BasePart** | `Anchored`, **`CanCollide=false`**, `CanTouch=true` | (58,0.5,48) **fond du Sas** | FuseService (`Touched` → `markEscaped`) |

> ⚠️ `Generator`, `ExitBarrier`, `ExitZone`, `FuseSpot{i}`, `SpawnPoint`
> **doivent être des BaseParts** (un Model est rejeté avec un warn).
> L'`ExitZone` est **au fond du Sas** (mur est) : une fois l'`ExitBarrier`
> ouverte au 5/5, le joueur **traverse toute la salle** pour s'évader.
> Le dossier **`Workspace.Fuses` est créé automatiquement** — ne pas le créer.

---

## 2. `ServerStorage` — assets

| ✓ | Chemin exact | Type | Notes |
|---|---|---|---|
| [ ] | `ServerStorage.Assets` | Folder | conteneur |
| [ ] | `ServerStorage.Assets.FuseTemplate` | **BasePart** | MVP : une Part colorée suffit. **Optionnel** : si absent, repli Part néon jaune créé en code (+ warn). |
| [ ] | `Workspace.Entity` | **Model** + `HumanoidRootPart` (BasePart) | **Optionnel / mode IA seulement** (1-2 joueurs, ou Écho humain qui quitte). Sans lui : warn + l'IA n'agit pas (manche tourne via timer/évasion). Inutile pour tester l'Écho **humain**. |

> ⚠️ `ServerStorage.Logic.*` vient de **Rojo**, à ne pas créer à la main.

---

## 3. ProximityPrompt — créés EN CODE (à vérifier en Play, pas à créer)

Instanciés par FuseService ; valeurs depuis `GameConfig.Interaction`.

| ✓ | Prompt | Sur | `ActionText` | `ObjectText` | `HoldDuration` | `MaxActivationDistance` | `RequiresLineOfSight` |
|---|---|---|---|---|---|---|---|
| [ ] | Fusible (×5) | chaque `Fuse{i}` | `Ramasser le fusible` | `Fusible` | **0** (`FuseGrabTime`) | **8** (`Interaction.Distance`) | `false` |
| [ ] | Générateur | `Map.Generator` | `Déposer le fusible` | `Générateur` | **0** | **8** | `false` |

- [ ] À ≤ 8 studs le bouton apparaît, ramassage **instantané** (HoldDuration 0).

---

## 4. Console **Output** au démarrage — séquence attendue

**Démarrage serveur (immédiat) :**
- [ ] `[Signal Lost] Serveur démarré.`
- [ ] `[RoundService] Transition de phase : Lobby -> Starting` (dès ≥ 1 joueur ; `MinPlayers=1`)

**Après `LobbyDuration` = 15 s :**
- [ ] `[RoundService] Transition de phase : Starting -> Playing`

**À l'entrée Playing — warns SEULEMENT si un asset optionnel manque (acceptables en MVP) :**
- [ ] `[FuseService] ServerStorage.Assets.FuseTemplate absent : Part de repli utilisée. ⚠️ asset.`
- [ ] `[EchoService] Workspace.Entity introuvable : ...` *(mode IA sans Entity)*

**Pendant la partie :**
- [ ] `[PlayerService] Joueur <id> : Alive -> Downed` (etc.)
- [ ] `[FuseService] 5/5 fusibles déposés — sortie déverrouillée.`

**Fin de manche :**
- [ ] `[RoundService] Transition de phase : Playing -> Resolved`
- [ ] `[RoundService] Transition de phase : Resolved -> Lobby` (après `IntermissionDuration` = 8 s)

### 🚩 Warns = item manquant à corriger (ne doivent PAS apparaître si la map est complète)
- [ ] `[RoundService] Workspace.Map introuvable ...` → `Map` mal nommé/absent
- [ ] `[RoundService] Workspace.Map.SpawnPoint introuvable ...` → SpawnPoint manquant
- [ ] `[FuseService] Workspace.Map.<X> introuvable. ⚠️` → objet de map manquant (Generator/ExitBarrier/ExitZone)
- [ ] `[FuseService] Workspace.Map.FuseSpots introuvable. ⚠️` → dossier intermédiaire `FuseSpots` manquant
- [ ] `[FuseService] Workspace.Map.FuseSpots.FuseSpot<i> introuvable. ⚠️` → un spot manquant
- [ ] `[FuseService] ... n'est pas une BasePart. ⚠️` → mauvais type (ex. Generator est un Model)
- [ ] `[FuseService] <n>/5 FuseSpot trouvés : le 5/5 sera INATTEIGNABLE. ⚠️` → FuseSpot manquant(s)

---

## 5. Combien de joueurs pour quel mode (⚠️ crucial pour tester)

`GameConfig.Roles.HumanEchoMinPlayers = 3`, figé au démarrage de manche :

- [ ] **Play Solo (1 joueur)** → **Écho IA** (le joueur est Survivor). Teste
      fusibles / sortie / évasion ; l'Écho IA exige `Workspace.Entity` pour agir.
- [ ] **2 joueurs** → toujours **Écho IA**.
- [ ] **≥ 3 joueurs** (Test → Players = 3 → Start) → **Écho HUMAIN** : un joueur
      reçoit `AssignRole = "Echo"`, les autres `"Survivor"`. **Seul mode qui
      exerce EchoController** (écholocation, Howl/Frenzy). ← vraie feature PvP.

---

## ⚠️ À valider en Studio / sur appareil

- [ ] **Sons** : `SoundConfig` contient des placeholders → remplacer par des
      `rbxassetid://` une fois les audios choisis (un id invalide ne plante pas).
- [ ] **Config de publication** (P2-11) : `StreamingEnabled`, budgets, etc.
- [ ] **Validation mobile** (P2-12) : boutons HUD tactiles, lisibilité, perfs sur
      appareil bas de gamme — à tester en device emulation puis sur vrai mobile.
- [ ] **Map** : vérifier en Play que les 5 FuseSpots, le Generator, l'ExitBarrier
      et l'ExitZone sont bien détectés (aucun warn `introuvable` en section 4).
