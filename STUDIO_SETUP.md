# Checklist Studio — « Signal Lost » serveur en conditions réelles

> **État du code de référence :** cette checklist a été écrite pour le commit
> [`9edca63`](https://github.com/entrane/roblox/commit/9edca638f787fa62dc445c192217d08a98536e56)
> (« Pivot PvP étape 6d : FuseService réel »). Si le code a évolué depuis,
> revérifier les noms d'objets / valeurs ci-dessous contre les Services.

Objectif : pouvoir ouvrir Studio, cocher chaque item, et faire **tourner la
boucle serveur PvP** (lobby → rôles → manche → fusibles → sortie → évasion/mort
→ résolution → intermission). ⚠️ Le **client (étape 9) n'existe pas encore** :
on observe le serveur via l'Output et les ProximityPrompt, pas via un HUD.

---

## 0. Pré-requis (avant de toucher la map)

- [ ] Rojo sync actif (`rojo serve` + plugin connecté) → `src/` peuplé dans
      ReplicatedStorage / ServerStorage / ServerScriptService / StarterPlayer.
- [ ] **`Workspace.Map` n'est PAS synchronisé par Rojo** (absent de
      `default.project.json`) → tout ce qui suit se construit **à la main**.
- [ ] Un sol / baseplate sous toute la scène (les persos tombent sinon ;
      `CharacterAutoLoads` est forcé à `false` par le code, spawns gérés via
      `LoadCharacter` + téléport).

---

## 1. `Workspace.Map` — objets à créer (noms EXACTS, sensibles à la casse)

> `Map` = Model ou Folder nommé exactement **`Map`**, enfant direct de `Workspace`.

| ✓ | Chemin exact | Type requis | Propriétés clés | Taille approx. | Utilisé par |
|---|---|---|---|---|---|
| [ ] | `Map.SpawnPoint` | **BasePart** (Part ou SpawnLocation) | `Anchored=true` | ~6×1×6 | RoundService (téléport au début de chaque phase, offset +Y) |
| [ ] | `Map.FuseSpots` | **Folder** (ou Model) | conteneur intermédiaire | — | FuseService (parent des 5 spots) |
| [ ] | `Map.FuseSpots.FuseSpot1` | **BasePart** | `Anchored=true` | ~2×1×2 | FuseService (fusible flotte à +3 Y au-dessus) |
| [ ] | `Map.FuseSpots.FuseSpot2` | **BasePart** | `Anchored=true` | ~2×1×2 | idem |
| [ ] | `Map.FuseSpots.FuseSpot3` | **BasePart** | `Anchored=true` | ~2×1×2 | idem |
| [ ] | `Map.FuseSpots.FuseSpot4` | **BasePart** | `Anchored=true` | ~2×1×2 | idem |
| [ ] | `Map.FuseSpots.FuseSpot5` | **BasePart** | `Anchored=true` | ~2×1×2 | idem |
| [ ] | `Map.Generator` | **BasePart** (⚠️ PAS un Model) | `Anchored=true`, `CanCollide=true` | ~6×6×4 | FuseService (prompt dépôt créé dessus ; fusible déposé flotte à +4 Y) |
| [ ] | `Map.ExitBarrier` | **BasePart** | `Anchored=true`, **`CanCollide=true`**, `Transparency=0` | mur bloquant la sortie | FuseService (au 5/5 → `CanCollide=false` + `Transparency=0.7`) |
| [ ] | `Map.ExitZone` | **BasePart** | `Anchored=true`, **`CanCollide=false`**, `CanTouch=true` | zone à franchir, **derrière** la barrière | FuseService (`Touched` → `markEscaped`) |

> ⚠️ `Generator`, `ExitBarrier`, `ExitZone`, `FuseSpot{i}`, `SpawnPoint`
> **doivent être des BaseParts** (un Model est rejeté avec un warn).
> Place `ExitZone` **derrière** `ExitBarrier` (on ne la touche qu'une fois la
> barrière ouverte).
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

## ⚠️ Limite connue (étape 9 manquante)

Sans client : en Play tu verras les **transitions serveur (Output)** et les
**ProximityPrompt**, mais **pas** de HUD, **pas** de marqueurs d'écholocation, et
les Remotes Écho (`ActivateAbility`) / survivant (sprint, torche, revive) ne sont
pas encore émis. Le serveur est **observable et pilotable au prompt**, l'expérience
complète attend l'étape 9.
