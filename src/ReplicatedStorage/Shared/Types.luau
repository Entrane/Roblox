--!strict
-- Types — Contrat de données partagé entre les modules Logic (ServerStorage) et
-- les Services (client/serveur).
--
-- Module quasi PUR : il ne définit que des types et des constantes d'enum gelées.
-- Seule entorse assumée à la « pureté » : l'usage du type-valeur `Vector3`
-- (ce n'est pas un service ni une Instance — la position entre toujours par
-- paramètre depuis un Service).
--
-- CONVENTION ENUM : chaque ensemble d'états est défini DEUX FOIS, côte à côte :
--   1. une union de littéraux (sécurité de type à la compilation),
--   2. une table de constantes gelée (évite les « magic strings » à l'exécution).
-- Les deux DOIVENT rester synchronisés — voir les commentaires dédiés.

local Types = {}

-- ═══════════════════════════════════════════════════════════════════════
-- JOUEUR
-- ═══════════════════════════════════════════════════════════════════════

-- États de vie possibles d'un joueur.
-- Escaped = survivant qui s'est échappé (issue PvP individuelle), terminal pour
-- la manche au même titre que Dead : exclu du ciblage de l'entité et compté comme
-- « résolu » (ni à secourir, ni à craindre).
export type PlayerLifeState = "Alive" | "Downed" | "Dead" | "Escaped"

-- ⚠️ DOIT rester synchronisé avec le type `PlayerLifeState` ci-dessus.
Types.LifeState = table.freeze({
	Alive = "Alive" :: "Alive",
	Downed = "Downed" :: "Downed",
	Dead = "Dead" :: "Dead",
	Escaped = "Escaped" :: "Escaped",
})

-- État logique complet d'un joueur (aucune donnée 3D ici).
export type PlayerState = {
	userId: number, -- identifiant Roblox du joueur
	lifeState: PlayerLifeState, -- vivant / à terre / mort
	stamina: number, -- 0 .. GameConfig.Stamina.Max
	battery: number, -- 0 .. GameConfig.Torch.BatteryMax
	isSprinting: boolean, -- sprint en cours (consomme la stamina)
	torchOn: boolean, -- torche allumée (consomme la batterie ; le client l'affiche)
	reviveProgress: number, -- progression de réanimation 0 .. GameConfig.Revive.Duration
}

-- Charge HUD poussée serveur→client à CHAQUE survivant (Remote PlayerHud, FireClient) :
-- le strict nécessaire à ses barres + son propre statut. `lifeState` permet au
-- client d'afficher « À TERRE / MORT / ÉVADÉ » (feedback de son propre état).
-- Anti-triche : un joueur ne reçoit QUE le sien, jamais celui d'un autre.
export type HudPlayerState = {
	stamina: number, -- 0 .. GameConfig.Stamina.Max
	battery: number, -- 0 .. GameConfig.Torch.BatteryMax
	lifeState: PlayerLifeState, -- pour le feedback d'état du joueur lui-même
	torchOn: boolean, -- état AUTORITAIRE de la torche (pilote la PointLight client)
}

-- ═══════════════════════════════════════════════════════════════════════
-- RÔLES (PvP 4v1)
-- ═══════════════════════════════════════════════════════════════════════

-- Rôle d'un joueur dans la manche. Un seul Echo ; les autres sont Survivor.
-- En mode 1-2 joueurs, l'Echo est piloté par l'IA (aucun joueur n'a ce rôle).
export type Role = "Survivor" | "Echo"

-- ⚠️ DOIT rester synchronisé avec le type `Role` ci-dessus.
Types.Role = table.freeze({
	Survivor = "Survivor" :: "Survivor",
	Echo = "Echo" :: "Echo",
})

-- ═══════════════════════════════════════════════════════════════════════
-- MANCHE
-- ═══════════════════════════════════════════════════════════════════════

-- Phases de la machine à états de manche.
-- Starting = décompte avant le lancement (annulable si on repasse sous MinPlayers).
-- Resolved = ÉTAT TERMINAL UNIQUE (ex-Victory/Defeat fusionnés) : la manche est
-- finie, le vainqueur est porté par RoundState.winner. Un seul écran de fin,
-- paramétré par la faction, au lieu de deux phases distinctes.
export type RoundPhase = "Lobby" | "Starting" | "Playing" | "Resolved"

-- ⚠️ DOIT rester synchronisé avec le type `RoundPhase` ci-dessus.
Types.RoundPhase = table.freeze({
	Lobby = "Lobby" :: "Lobby",
	Starting = "Starting" :: "Starting",
	Playing = "Playing" :: "Playing",
	Resolved = "Resolved" :: "Resolved",
})

-- Faction gagnante d'une manche PvP (argument de l'éventuel onRoundResolved).
-- RoundManager reste IGNORANT des rôles : c'est le Service qui calcule le
-- vainqueur et le lui transmet (décision actée). « Survivors » = au moins un
-- échappé selon la règle de fin ; « Echo » = tous résolus sans victoire survivant,
-- ou timer écoulé.
export type Faction = "Survivors" | "Echo"

-- ⚠️ DOIT rester synchronisé avec le type `Faction` ci-dessus.
Types.Faction = table.freeze({
	Survivors = "Survivors" :: "Survivors",
	Echo = "Echo" :: "Echo",
})

-- État logique de la manche en cours.
-- INVARIANT garanti par RoundManager.getState() : `winner` est non-nil SI ET
-- SEULEMENT SI `phase == Resolved`. Hors état terminal, il vaut toujours nil.
export type RoundState = {
	phase: RoundPhase, -- phase courante
	timeRemaining: number, -- secondes restantes dans la phase courante
	winner: Faction?, -- faction gagnante en phase Resolved, nil sinon
}

-- ═══════════════════════════════════════════════════════════════════════
-- FUSIBLES
-- ═══════════════════════════════════════════════════════════════════════

-- Cycle de vie d'un fusible : caché → porté par un joueur → déposé au générateur.
export type FuseLifeState = "Hidden" | "Carried" | "Deposited"

-- ⚠️ DOIT rester synchronisé avec le type `FuseLifeState` ci-dessus.
Types.FuseLifeState = table.freeze({
	Hidden = "Hidden" :: "Hidden",
	Carried = "Carried" :: "Carried",
	Deposited = "Deposited" :: "Deposited",
})

-- État logique d'un fusible unique (aucune position 3D ici).
export type Fuse = {
	id: number, -- identifiant logique du fusible
	state: FuseLifeState, -- caché / porté / déposé
	carriedBy: number?, -- userId du porteur, ou nil si non porté
}

-- Progression de l'objectif fusibles (le « 0/5 » à afficher).
export type FuseProgress = {
	collected: number, -- nombre déposés au générateur
	required: number, -- cible (= GameConfig.Fuses.Total)
}

-- ═══════════════════════════════════════════════════════════════════════
-- ENTITÉ (IA)
-- ═══════════════════════════════════════════════════════════════════════

-- Phases de la machine à états de l'entité.
export type EntityPhase = "Patrol" | "Search" | "Chase" | "Attack"

-- ⚠️ DOIT rester synchronisé avec le type `EntityPhase` ci-dessus.
Types.EntityPhase = table.freeze({
	Patrol = "Patrol" :: "Patrol",
	Search = "Search" :: "Search",
	Chase = "Chase" :: "Chase",
	Attack = "Attack" :: "Attack",
})

-- État logique de l'entité.
-- `lastKnownPosition` : seule donnée 3D du contrat (type-valeur Vector3),
-- fournie par un Service. nil tant qu'aucune cible n'a été repérée.
export type EntityState = {
	phase: EntityPhase, -- patrouille / recherche / poursuite / attaque
	targetUserId: number?, -- cible courante, ou nil
	stateTimer: number, -- temps écoulé (s) dans la phase courante
	lastKnownPosition: Vector3?, -- dernière position connue de la cible, ou nil
}

-- Entrée fournie À EntityAI à chaque update, une par joueur ENCORE SUIVI par
-- la partie (pas seulement les joueurs visibles — l'absence d'une entrée a un
-- sens distinct : le joueur a quitté la partie, voir EntityAI). Toute la
-- géométrie (raycast, cône de vision, occlusion sonore) est déjà résolue par
-- le Service ici : EntityAI ne fait que des comparaisons numériques sur ces
-- champs, jamais de calcul 3D.
export type EntityObservation = {
	userId: number,
	distance: number, -- studs, scalaire déjà calculé par le Service
	visible: boolean, -- Service a résolu Raycast + SightRange + SightAngle
	audible: boolean, -- Service a résolu HearRange + bruit (sprint, via PlayerState)
	lifeState: PlayerLifeState, -- Alive / Downed / Dead, lu par le Service dans PlayerState
	position: Vector3?, -- position actuelle, fournie seulement si visible ou audible
}

-- ═══════════════════════════════════════════════════════════════════════
-- ÉCHO (capacités partagées humain/IA + écholocation)
-- ═══════════════════════════════════════════════════════════════════════

-- Capacités activables de l'Écho. Sert à ROUTER une demande d'activation vers
-- la bonne capacité, que la source soit humaine (Remote) ou IA (EchoController
-- décide) — décision #1 : capacités dans EchoController, source d'input abstraite.
export type AbilityId = "Howl" | "Frenzy"

-- ⚠️ DOIT rester synchronisé avec le type `AbilityId` ci-dessus.
Types.AbilityId = table.freeze({
	Howl = "Howl" :: "Howl",
	Frenzy = "Frenzy" :: "Frenzy",
})

-- État d'une capacité : temps avant réutilisation et temps d'effet restant.
--   cooldownRemaining > 0  → indisponible (en recharge)
--   activeRemaining   > 0  → effet en cours (ex. frénésie active)
-- Howl, à effet instantané, n'utilise activeRemaining que pour la durée de
-- révélation renforcée ; Frenzy l'utilise pour la durée du bonus de vitesse.
export type AbilityState = {
	cooldownRemaining: number,
	activeRemaining: number,
}

-- État logique de l'Écho, répliqué au SEUL client Écho (HUD des cooldowns).
-- Pas d'état d'écholocation ici : elle est recalculée à chaque pulse à partir
-- des observations, sans persistance (décision #2).
export type EchoState = {
	howl: AbilityState,
	frenzy: AbilityState,
}

-- Charge MINIMALE d'écholocation envoyée serveur→client Écho : juste qui et où.
-- ⚠️ CONTRAINTE ANTI-TRICHE NON NÉGOCIABLE (décision #9) : ce type ne doit
-- JAMAIS être répliqué à un client survivant. Le serveur le calcule à partir du
-- pipeline EntityObservation (positions déjà résolues) et ne l'émet qu'au joueur
-- Écho. On n'embarque pas visible/audible/lifeState : le strict nécessaire au
-- marqueur visuel, rien de plus.
export type EcholocationPing = {
	userId: number,
	position: Vector3,
}

-- ═══════════════════════════════════════════════════════════════════════
-- PROGRESSION (XP / niveaux / quêtes) — contrats des Remotes serveur→client
-- ═══════════════════════════════════════════════════════════════════════

-- Détail des composants d'XP gagnés sur une manche (affichage de fin).
export type XpBreakdown = {
	participation: number,
	escaped: number,
	deposits: number,
	revives: number,
	kills: number,
	quests: number, -- récompenses de quêtes complétées CETTE manche
}

-- Stats INDIVIDUELLES brutes d'une manche (comptes, pas de l'XP). Affichées sous
-- le gain XP en fin de manche. `survivalSeconds` = durée Playing jusqu'à
-- mort/évasion du joueur (ou fin de manche s'il a survécu).
export type RoundStats = {
	deposits: number, -- fusibles déposés
	revives: number, -- réanimations réussies
	kills: number, -- kills (0 si pas l'Écho)
	survivalSeconds: number,
}

-- Payload XpResult (FireClient, fin de manche). `friendBonus` = XP bonus dû aux
-- amis (déjà inclus dans xpGained). `suggestInvite` = manche à < 4 joueurs.
-- `newTitles` = titres débloqués CETTE manche (pour « Titre débloqué : X ! »).
export type XpResult = {
	xp: number, -- XP total cumulé
	level: number, -- niveau dérivé de xp
	xpGained: number, -- XP gagné CETTE manche (perf×bonus amis + quêtes)
	breakdown: XpBreakdown,
	stats: RoundStats, -- compteurs bruts de la manche
	activeTitle: string?, -- titre actif (auto = dernier débloqué pour le MVP)
	newTitles: { string }, -- titres fraîchement débloqués cette manche
	friendBonus: number,
	friendCount: number,
	suggestInvite: boolean,
	playerCount: number,
}

-- Une quête journalière (état répliqué au client).
export type Quest = {
	id: string,
	label: string,
	progress: number, -- avancement courant
	goal: number, -- objectif (3 pour "jouer 3 parties", 1 pour les autres)
	complete: boolean,
	xpReward: number,
}

-- Payload QuestState (FireClient, au chargement + après chaque manche). Porte
-- aussi le niveau, le titre actif ET la liste des titres débloqués → le lobby
-- les affiche et propose le choix manuel du titre, sans attendre un XpResult.
export type QuestState = {
	quests: { Quest },
	level: number,
	activeTitle: string?,
	unlockedTitles: { string }, -- titres possédés (pour le panneau de sélection)
}

-- Une ligne du leaderboard de fin de manche. `name` = DisplayName résolu côté
-- serveur (gère un joueur parti, évite un lookup client). `won` = appartient à
-- la faction gagnante. Toutes les valeurs concernent CETTE manche (pas la vie).
export type LeaderboardEntry = {
	userId: number, -- pour que le client surligne SA ligne
	name: string,
	isEcho: boolean, -- rôle affiché (Écho / Survivant)
	won: boolean, -- sur la faction gagnante (mise en évidence)
	xpGained: number, -- clé de tri (décroissant)
	kills: number,
	deposits: number,
	revives: number,
	survivalSeconds: number,
}

-- Payload RoundLeaderboard (FireAllClients, UNE fois au Resolved). Données NON
-- secrètes (post-manche) → broadcast à tous. `entries` est DÉJÀ trié (rang =
-- position dans la liste).
export type RoundLeaderboard = {
	winner: Faction?,
	entries: { LeaderboardEntry },
}

-- Payload VoteState (FireAllClients) : avancement du vote « rejouer » en Resolved.
-- Diffusé à l'entrée en Resolved (0 / total) puis à chaque vote (compteur live).
export type VoteState = {
	yesCount: number,
	totalCount: number,
}

return Types
