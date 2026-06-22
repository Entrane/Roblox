--!strict
-- FuseSystem — Suivi de l'état logique des fusibles (cycle Hidden → Carried →
-- Deposited) et de la progression de l'objectif (le « 0/5 »).
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR : aucune donnée 3D, aucun emplacement, aucune Instance Roblox. Le
-- PLACEMENT physique d'un fusible (où il apparaît dans la map) est l'affaire du
-- futur FuseService — FuseSystem ne connaît que l'identité (id) et l'état
-- logique (Hidden/Carried/Deposited, carriedBy).
--
-- PASSIF, comme RoundManager et PlayerState : il ne notifie personne et
-- n'appelle aucun autre module Logic. En particulier, FuseSystem NE CONNAÎT
-- PAS PlayerState ni RoundManager :
--   - le départ d'un joueur, sa mise à Downed/Dead → c'est le SERVICE qui
--     détecte (en comparant l'état PlayerState à chaque tick, comme il le fait
--     déjà pour câbler RoundManager) et appelle releaseCarriedBy(userId) au bon
--     moment. Un seul point d'entrée pour les trois causes (départ, Downed,
--     Dead) : ce module ne distingue pas la cause, seulement l'effet.
--   - la décision « objectif complet » NE SE PREND PAS ICI : FuseSystem expose
--     seulement le FAIT (getProgress) ; c'est au Service de combiner ce fait avec
--     d'autres conditions du monde (ex. sortie atteinte) avant de résoudre la
--     manche via RoundService. Le « 5 fusibles déposés » n'est qu'un JALON, pas
--     la fin : la fin, c'est « sortie atteinte » (évasion individuelle en PvP).
--
-- Pas de update(dt) dans ce module : GameConfig.Interaction.FuseGrabTime = 0
-- (ramassage instantané) ⇒ aucun état n'évolue avec le temps. Si un futur temps
-- de maintien est ajouté, il sera vraisemblablement géré côté Service (timer
-- d'interaction), pas ici.
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- CHOIX ASSUMÉ — require uniforme (vs injection), voir RoundManager/PlayerState :
-- GameConfig et Types sont des constantes/types figés. Les require sont
-- volontairement ISOLÉS dans l'unique bloc ci-dessous.
--
-- CHOIX ASSUMÉ — identité des fusibles FOURNIE PAR LE SERVICE (registerFuse
-- prend un id externe), pas auto-générée ici : l'id doit être corrélable par le
-- Service à une position 3D / Instance Roblox ; plus simple si c'est lui qui le
-- choisit au moment du placement plutôt que de mapper un id auto-généré après
-- coup.
--
-- CHOIX ASSUMÉ — un seul fusible porté par joueur à la fois (règle validée) :
-- pickup() échoue si l'utilisateur porte déjà un autre fusible. Évite qu'un
-- seul joueur ramasse tout le contenu en un passage.
--
-- ⚠️ TODO — À FAIRE CÔTÉ FUTUR FuseService, PAS ICI (Tâche 3) : au démarrage
-- d'une manche, vérifier que le nombre de fusibles enregistrés (registerFuse)
-- correspond bien à GameConfig.Fuses.Total, et logguer une erreur claire si ce
-- n'est pas le cas. Sans ce garde-fou, un fusible manquant (erreur de placement
-- dans Studio) bloquerait SILENCIEUSEMENT toute la manche : getProgress().required
-- reste figé à Fuses.Total même si moins de fusibles existent réellement, donc
-- le « 5/5 » devient inatteignable sans aucun message expliquant pourquoi.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local FuseSystem = {}
FuseSystem.__index = FuseSystem

-- État interne = exactement le contrat Types.Fuse (id, state, carriedBy).
-- Contrairement à PlayerState, aucun champ interne à cacher : rien à projeter.
export type FuseSystem = typeof(setmetatable(
	{} :: {
		fuses: { [number]: Types.Fuse },
	},
	FuseSystem
))

-- ───────────────────────────────────────────────────────────────────────
-- Helpers privés
-- ───────────────────────────────────────────────────────────────────────

-- Vrai si userId porte déjà un fusible (règle : un seul à la fois). Scan O(n)
-- sur le registre — négligeable, GameConfig.Fuses.Total est petit (5).
local function isCarryingAny(self: FuseSystem, userId: number): boolean
	for _, fuse in self.fuses do
		if fuse.state == Types.FuseLifeState.Carried and fuse.carriedBy == userId then
			return true
		end
	end
	return false
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction & gestion du registre
-- ───────────────────────────────────────────────────────────────────────

function FuseSystem.new(): FuseSystem
	local self = setmetatable({}, FuseSystem) :: FuseSystem
	self.fuses = {}
	return self
end

-- Enregistre un nouveau fusible Hidden, sans porteur. Idempotent : un id déjà
-- connu n'est PAS réécrasé (préserve l'état courant, ex. déjà Carried).
function FuseSystem.registerFuse(self: FuseSystem, fuseId: number)
	if type(fuseId) ~= "number" then
		return
	end
	if self.fuses[fuseId] then
		return
	end
	self.fuses[fuseId] = {
		id = fuseId,
		state = Types.FuseLifeState.Hidden,
		carriedBy = nil,
	}
end

-- ───────────────────────────────────────────────────────────────────────
-- Événements entrants (transitions)
-- ───────────────────────────────────────────────────────────────────────

-- T1 : Hidden → Carried. Échoue (false) si le fusible est inconnu, n'est pas
-- Hidden (déjà Carried par un autre ou déjà Deposited — un seul test couvre
-- les deux cas), ou si l'utilisateur porte déjà un autre fusible.
function FuseSystem.pickup(self: FuseSystem, fuseId: number, userId: number): boolean
	if type(fuseId) ~= "number" or type(userId) ~= "number" then
		return false
	end
	local fuse = self.fuses[fuseId]
	if not fuse or fuse.state ~= Types.FuseLifeState.Hidden then
		return false
	end
	if isCarryingAny(self, userId) then
		return false
	end

	fuse.state = Types.FuseLifeState.Carried
	fuse.carriedBy = userId
	return true
end

-- T2 : Carried → Deposited. Échoue (false) si le fusible est inconnu, n'est
-- pas Carried, ou si le déposant n'est pas le porteur réel (défensif contre un
-- appel erroné/usurpé du Service).
function FuseSystem.deposit(self: FuseSystem, fuseId: number, userId: number): boolean
	if type(fuseId) ~= "number" or type(userId) ~= "number" then
		return false
	end
	local fuse = self.fuses[fuseId]
	if not fuse or fuse.state ~= Types.FuseLifeState.Carried or fuse.carriedBy ~= userId then
		return false
	end

	fuse.state = Types.FuseLifeState.Deposited
	fuse.carriedBy = nil
	return true
end

-- T3 : Carried → Hidden, pour TOUS les fusibles portés par userId. Point
-- d'entrée UNIQUE pour : départ de la partie, mise à Downed, mise à Dead — ce
-- module ne distingue pas la cause (cf. bloc PURETÉ & PASSIVITÉ ci-dessus) ;
-- c'est au Service de l'appeler au bon moment. Joueur inconnu/sans fusible →
-- no-op silencieux.
function FuseSystem.releaseCarriedBy(self: FuseSystem, userId: number)
	if type(userId) ~= "number" then
		return
	end
	for _, fuse in self.fuses do
		if fuse.state == Types.FuseLifeState.Carried and fuse.carriedBy == userId then
			fuse.state = Types.FuseLifeState.Hidden
			fuse.carriedBy = nil
		end
	end
end

-- T5 : repasse TOUS les fusibles enregistrés à Hidden (nouvelle manche). Ne
-- touche ni au nombre de fusibles enregistrés ni à GameConfig.Fuses.Total.
function FuseSystem.resetRound(self: FuseSystem)
	for _, fuse in self.fuses do
		fuse.state = Types.FuseLifeState.Hidden
		fuse.carriedBy = nil
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Requêtes (pures, sans effet de bord)
-- ───────────────────────────────────────────────────────────────────────

-- Snapshot d'un fusible (copie défensive : l'appelant ne doit jamais pouvoir
-- muter l'état interne par référence). nil si id inconnu.
function FuseSystem.getState(self: FuseSystem, fuseId: number): Types.Fuse?
	local fuse = self.fuses[fuseId]
	if not fuse then
		return nil
	end
	return {
		id = fuse.id,
		state = fuse.state,
		carriedBy = fuse.carriedBy,
	}
end

-- Snapshot de tous les fusibles (réplication HUD / positionnement 3D côté Service).
function FuseSystem.getAllStates(self: FuseSystem): { [number]: Types.Fuse }
	local out: { [number]: Types.Fuse } = {}
	for fuseId in self.fuses do
		local snap = self:getState(fuseId)
		if snap then
			out[fuseId] = snap
		end
	end
	return out
end

-- Progression de l'objectif (le « 0/5 » affiché au HUD). `required` vient de
-- GameConfig (source de vérité de config), PAS du nombre de fusibles réellement
-- enregistrés — voir le TODO Service en tête de fichier en cas d'écart.
function FuseSystem.getProgress(self: FuseSystem): Types.FuseProgress
	local collected = 0
	for _, fuse in self.fuses do
		if fuse.state == Types.FuseLifeState.Deposited then
			collected += 1
		end
	end
	return {
		collected = collected,
		required = GameConfig.Fuses.Total,
	}
end

return FuseSystem
