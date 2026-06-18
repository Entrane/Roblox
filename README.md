# Signal Lost

Jeu d'horreur coopératif sur Roblox (1 à 4 joueurs).

> **Pitch :** Piégés dans un bunker sombre, trouvez 5 fusibles cachés, rapportez-les
> au générateur, puis atteignez la sortie — pendant qu'une entité IA vous traque
> au son et à la vue. Un joueur mis à terre peut être réanimé par un coéquipier
> (3 s). Si tout le monde est à terre, c'est la défaite.

---

## État du projet

Développement **sans Roblox Studio** pour l'instant : tout le code vit dans ce repo
en fichiers `.luau`, structuré pour une synchronisation [Rojo](https://rojo.space)
vers Studio plus tard.

- ✅ **Tâche 1** — Structure du projet Rojo (ce commit).
- ⏳ **Tâche 2** — ModuleScripts de logique pure (`GameConfig`, `RoundManager`,
  `FuseSystem`, `PlayerState`, `EntityAI`).
- ⏳ **Tâche 3** — Câblage client/serveur avec TODO pour les objets 3D.
- 🚫 **Hors périmètre actuel** — map, terrain, éclairage, assets : attend Studio.

---

## Architecture

```
src/
├── ReplicatedStorage/
│   ├── Shared/      → Config, types et helpers PURS (lus par client + serveur)
│   └── Remotes/     → Déclaration centralisée des RemoteEvents
│
├── ServerStorage/
│   └── Logic/       → Logique serveur-autoritaire PURE (jamais répliquée au client)
│                      RoundManager, FuseSystem, PlayerState, EntityAI
│
├── ServerScriptService/
│   └── Server/      → init.server.luau requiert et initialise les Services DANS L'ORDRE
│
└── StarterPlayer/StarterPlayerScripts/
    └── Client/      → init.client.luau requiert et initialise les Controllers DANS L'ORDRE
```

### Principes

- **Serveur autoritaire.** Toute la logique de jeu (manche, fusibles, état joueur,
  IA) tourne sur le serveur depuis `ServerStorage`/`ServerScriptService`. Le client
  ne reçoit que l'**état affichable** via les Remotes — jamais la logique sensible.
- **Init déterministe.** Aucun `Script`/`LocalScript` indépendant ne se lance en
  parallèle : un unique point d'entrée par côté (`init.server.luau`,
  `init.client.luau`) requiert et initialise les modules dans un ordre maîtrisé.
- **Logique pure ≠ câblage runtime.** Les modules de `ServerStorage/Logic`
  contiennent la logique de domaine testable et indépendante de la 3D. Les Services
  de `ServerScriptService/Server` les pilotent et font le lien avec les Remotes et
  les futurs objets 3D.
- **Mobile-first, code défensif.** Vérification des `nil`, hypothèses sur les API
  documentées dans le code, et marquage `-- ⚠️ À VALIDER DANS STUDIO` partout où une
  hypothèse devra être confirmée une fois en jeu.

### Convention de nommage Rojo

| Suffixe de fichier   | Instance Roblox générée |
| -------------------- | ----------------------- |
| `Nom.luau`           | `ModuleScript`          |
| `Nom.server.luau`    | `Script` (serveur)      |
| `Nom.client.luau`    | `LocalScript` (client)  |
| `init.luau`          | `ModuleScript` portant le nom du dossier parent |
| `init.server.luau`   | `Script` portant le nom du dossier parent |
| `init.client.luau`   | `LocalScript` portant le nom du dossier parent |

---

## Installer Rojo

Rojo synchronise les fichiers de ce repo vers Roblox Studio.

### 1. Installer le binaire Rojo

Le plus simple est [Aftman](https://github.com/LPGhatguy/aftman) (gestionnaire de
toolchains Roblox), déjà déclaré dans... *(à venir)*. Sinon, installation directe :

```bash
# Via Cargo (Rust)
cargo install rojo

# Ou via Aftman (recommandé pour figer la version dans le repo)
aftman add rojo-rbx/rojo
aftman install

# Vérifier
rojo --version
```

### 2. Installer le plugin Studio

Une fois le binaire installé :

```bash
rojo plugin install
```

…ou installe le plugin **Rojo** depuis la Creator Store de Roblox Studio.

---

## Brancher Studio (plus tard)

Quand on passera à Studio :

1. Ouvrir un **nouveau Place vide** (Baseplate) dans Roblox Studio.
2. Dans un terminal, à la racine du repo, lancer le serveur de synchro :
   ```bash
   rojo serve
   ```
   Rojo lit `default.project.json` et expose le projet sur `localhost:34872`.
3. Dans Studio, ouvrir le plugin **Rojo** → **Connect**.
4. Le contenu de `src/` apparaît alors dans `ReplicatedStorage`, `ServerStorage`,
   `ServerScriptService` et `StarterPlayer`. Toute modification d'un `.luau` dans le
   repo est répercutée en direct dans Studio.

### Construire un fichier de place (sans synchro live)

```bash
rojo build -o SignalLost.rbxlx
```

Ouvre ensuite `SignalLost.rbxlx` dans Studio. *(Le `.rbxlx` est ignoré par Git.)*

---

## Workflow de développement

1. Coder dans `src/` (ce repo), commits par tâche.
2. `rojo serve` + plugin connecté → tester en Play Solo / multi dans Studio.
3. Les assets 3D (map, spawns, modèle d'entité, ScreenGui) sont créés **dans
   Studio** ; le code y fait référence via des TODO clairement marqués tant qu'ils
   n'existent pas.

> ⚠️ **À valider dans Studio** : tous les emplacements marqués
> `-- ⚠️ À VALIDER DANS STUDIO` dans le code reposent sur des hypothèses d'API ou
> sur des objets 3D non encore présents. À confirmer dès la première session Studio.
