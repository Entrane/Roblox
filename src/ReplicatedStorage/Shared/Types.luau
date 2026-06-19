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
export type PlayerLifeState = "Alive" | "Downed" | "Dead"

-- ⚠️ DOIT rester synchronisé avec le type `PlayerLifeState` ci-dessus.
Types.LifeState = table.freeze({
	Alive = "Alive" :: "Alive",
	Downed = "Downed" :: "Downed",
	Dead = "Dead" :: "Dead",
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

-- ═══════════════════════════════════════════════════════════════════════
-- MANCHE
-- ═══════════════════════════════════════════════════════════════════════

-- Phases de la machine à états de manche.
-- Starting = décompte avant le lancement (annulable si on repasse sous MinPlayers).
export type RoundPhase = "Lobby" | "Starting" | "Playing" | "Victory" | "Defeat"

-- ⚠️ DOIT rester synchronisé avec le type `RoundPhase` ci-dessus.
Types.RoundPhase = table.freeze({
	Lobby = "Lobby" :: "Lobby",
	Starting = "Starting" :: "Starting",
	Playing = "Playing" :: "Playing",
	Victory = "Victory" :: "Victory",
	Defeat = "Defeat" :: "Defeat",
})

-- État logique de la manche en cours.
export type RoundState = {
	phase: RoundPhase, -- phase courante
	timeRemaining: number, -- secondes restantes dans la phase courante
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

return Types
