--!strict
-- EntityAI — FSM de l'entité traqueuse (Patrol → Chase → Search → Attack).
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR : aucune dépendance 3D/Roblox dans la décision elle-même. Toute
-- la géométrie (Raycast, cône de vision, occlusion sonore) est résolue par le
-- futur EntityService et fournie comme FAIT déjà tranché via
-- Types.EntityObservation (visible/audible/distance/position/lifeState).
-- EntityAI ne fait que des comparaisons numériques sur des valeurs déjà
-- reçues (AttackRange, SearchDuration, LoseTargetTime, AttackCooldown) —
-- jamais de Raycast, jamais de trigo, jamais de pathfinding.
--
-- PASSIF, comme RoundManager/PlayerState/FuseSystem : aucun appel à un autre
-- module Logic. En particulier EntityAI ne connaît ni PlayerState ni
-- RoundManager :
--   - `lifeState` (Alive/Downed/Dead) arrive tout fait dans chaque
--     observation, fourni par le Service qui lit PlayerState ;
--   - le coup qui part n'est jamais appliqué ici : update() le SIGNALE (voir
--     plus bas), c'est au Service d'appeler PlayerState.applyAttack(userId) ;
--   - c'est au Service de ne PAS appeler update() hors de la phase Playing de
--     RoundManager (EntityAI n'a aucune notion de phase de manche).
--
-- Point d'entrée UNIQUE par tick : update(dt, observations). Contrairement à
-- RoundManager/PlayerState/FuseSystem, pas d'événements discrets séparés
-- (onPlayerJoined, applyAttack, etc.) : la visibilité/l'audibilité sont des
-- signaux CONTINUS réévalués chaque frame, pas des événements ponctuels du
-- monde — ils n'ont donc pas besoin de leur propre fonction.
--
-- Une instance = UNE entité (comme RoundManager, pas un registre comme
-- PlayerState/FuseSystem). Pas de resetRound() : le Service recrée une
-- instance neuve (EntityAI.new()) à chaque manche plutôt que de devoir se
-- souvenir de remettre à zéro les champs internes en plus des publics.
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- CHOIX ASSUMÉ — require uniforme (vs injection), voir les modules
-- précédents : GameConfig et Types sont des constantes/types figés. Les
-- require sont volontairement ISOLÉS dans l'unique bloc ci-dessous.
--
-- CHOIX ASSUMÉ — priorité de ciblage Alive > Downed, en DERNIER RECOURS
-- seulement : un Downed n'est ciblable que si AUCUN Alive n'a de contact
-- (visible/audible) à cet instant. Pas de priorité absolue (punitif), pas de
-- délai de grâce supplémentaire (GameConfig.Revive.BleedOutTime joue déjà ce
-- rôle côté PlayerState). Voir Types.EntityObservation pour le contrat.
--
-- CHOIX ASSUMÉ — aucune ré-évaluation de cible en cours d'engagement : une
-- fois targetUserId verrouillé (Chase/Attack), il ne change QUE via les
-- conditions de sortie explicites ci-dessous (perte de contact prolongée,
-- cible disparue ou morte). Un candidat plus proche ou plus "intéressant" qui
-- apparaît en cours de route est ignoré — comportement voulu, pas un oubli :
-- une IA qui réévalue en permanence devient imprévisible/inéquitable.
--
-- CHOIX ASSUMÉ — le son (audible) déclenche/réoriente (Patrol→Chase,
-- Search→Chase) mais NE SOUTIENT PAS un contact déjà établi en Chase, et NE
-- RAFRAÎCHIT JAMAIS lastKnownPosition : seule la vue (visible) le fait. Sinon
-- le bruit du sprint (précisément le moment où le joueur en a besoin pour
-- fuir) annulerait l'intérêt de casser la ligne de vue — voir le bloc
-- « INTENTION DE DESIGN » dans GameConfig.
--
-- CHOIX ASSUMÉ — signal de frappe explicite : update() RETOURNE le userId
-- frappé ce tick précis (ou nil), plutôt qu'un champ persistant dans
-- Types.EntityState. Un coup qui part est un événement instantané, pas un
-- état à répliquer — cohérent avec RoundManager.onPlayerJoined qui retourne
-- directement un booléen plutôt que de le stocker. attackCooldownTimer
-- décompte EN CONTINU, quelle que soit la phase (jamais remis à zéro en
-- entrant/sortant d'Attack, seulement quand un coup part réellement) : sinon
-- l'entité pourrait "rafraîchir" son cooldown gratuitement en sortant puis
-- rentrant en portée.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local EntityAI = {}
EntityAI.__index = EntityAI

-- État interne + méthodes (via metatable). noContactTimer et
-- attackCooldownTimer sont INTERNES (jamais exposés par getState()), même
-- principe que regenCooldown/bleedOutTimer dans le Record de PlayerState.
export type EntityAI = typeof(setmetatable(
	{} :: {
		phase: Types.EntityPhase,
		targetUserId: number?,
		stateTimer: number, -- temps écoulé (s) dans la phase courante (public)
		lastKnownPosition: Vector3?,
		noContactTimer: number, -- (interne) temps sans VOIR la cible, gouverne Chase -> Search
		attackCooldownTimer: number, -- (interne) décompte en continu, gouverne le signal de frappe
	},
	EntityAI
))

-- ───────────────────────────────────────────────────────────────────────
-- Helpers privés (purs, sur la liste d'observations reçue ce tick)
-- ───────────────────────────────────────────────────────────────────────

local function hasContact(obs: Types.EntityObservation): boolean
	return obs.visible or obs.audible
end

-- Sélectionne le meilleur candidat éligible : Alive prioritaire sur Downed
-- (priorité dernier-recours, cf. bloc DÉPENDANCES), puis le plus proche, puis
-- le userId le plus petit en cas d'égalité exacte de distance (déterministe :
-- l'itération d'une table Lua n'a pas d'ordre garanti). Dead toujours exclu.
-- nil si aucun candidat éligible n'a de contact.
local function selectTarget(observations: { Types.EntityObservation }): Types.EntityObservation?
	local bestAlive: Types.EntityObservation? = nil
	local bestDowned: Types.EntityObservation? = nil

	for _, obs in observations do
		if hasContact(obs) and obs.lifeState ~= Types.LifeState.Dead then
			if obs.lifeState == Types.LifeState.Alive then
				if not bestAlive or obs.distance < bestAlive.distance or (obs.distance == bestAlive.distance and obs.userId < bestAlive.userId) then
					bestAlive = obs
				end
			elseif obs.lifeState == Types.LifeState.Downed then
				if not bestDowned or obs.distance < bestDowned.distance or (obs.distance == bestDowned.distance and obs.userId < bestDowned.userId) then
					bestDowned = obs
				end
			end
		end
	end

	-- Un seul Alive avec contact suffit à exclure tous les Downed (dernier recours).
	return bestAlive or bestDowned
end

-- Retrouve l'observation d'un userId précis dans la liste reçue ce tick.
-- nil si absent (cible inconnue/disparue du monde) ou si userId est nil.
local function findObservation(observations: { Types.EntityObservation }, userId: number?): Types.EntityObservation?
	if userId == nil then
		return nil
	end
	for _, obs in observations do
		if obs.userId == userId then
			return obs
		end
	end
	return nil
end

-- Règle transverse (Partie D) : la cible verrouillée a disparu du monde
-- (absente de la liste -- départ) OU est passée Dead (achevée, ou morte par
-- une autre voie comme le saignement). Dans les deux cas, plus aucune raison
-- de la suivre ou de la chercher.
local function isTargetGone(current: Types.EntityObservation?): boolean
	return current == nil or current.lifeState == Types.LifeState.Dead
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

-- État initial : Patrol, aucune cible. Aucun effet de bord.
function EntityAI.new(): EntityAI
	local self = setmetatable({}, EntityAI) :: EntityAI
	self.phase = Types.EntityPhase.Patrol
	self.targetUserId = nil
	self.stateTimer = 0
	self.lastKnownPosition = nil
	self.noContactTimer = 0
	self.attackCooldownTimer = 0
	return self
end

-- ───────────────────────────────────────────────────────────────────────
-- Transitions privées (entrée dans un état : pose phase + timer + cible)
-- Chaque _enterX applique UNE transition. Préfixe _ = usage interne.
-- ───────────────────────────────────────────────────────────────────────

function EntityAI._enterPatrol(self: EntityAI)
	self.phase = Types.EntityPhase.Patrol
	self.stateTimer = 0
	self.targetUserId = nil
	self.lastKnownPosition = nil
	self.noContactTimer = 0
	-- attackCooldownTimer NON remis à zéro : il persiste à travers les phases.
end

-- targetUserId est TOUJOURS fourni explicitement : soit une nouvelle cible
-- choisie par selectTarget (Patrol/Search -> Chase), soit la même cible
-- conservée lors d'une rétrogradation Attack -> Chase. position est optionnel
-- : s'il est fourni (toujours le cas pour une nouvelle cible, puisque
-- selectTarget exige hasContact), lastKnownPosition est rafraîchie ; sinon
-- elle est CONSERVÉE telle quelle (cas Attack -> Chase sans vue ce tick-là).
function EntityAI._enterChase(self: EntityAI, targetUserId: number, position: Vector3?)
	self.phase = Types.EntityPhase.Chase
	self.stateTimer = 0
	self.targetUserId = targetUserId
	if position then
		self.lastKnownPosition = position
	end
	self.noContactTimer = 0
end

-- targetUserId et lastKnownPosition CONSERVÉS (on part chercher à la
-- dernière position connue, cf. tableau de transitions Partie B/D).
function EntityAI._enterSearch(self: EntityAI)
	self.phase = Types.EntityPhase.Search
	self.stateTimer = 0
end

-- targetUserId et lastKnownPosition CONSERVÉS. attackCooldownTimer NON remis
-- à zéro (persiste, voir bloc DÉPENDANCES).
function EntityAI._enterAttack(self: EntityAI)
	self.phase = Types.EntityPhase.Attack
	self.stateTimer = 0
end

-- ───────────────────────────────────────────────────────────────────────
-- update — SEUL point d'entrée par tick
-- ───────────────────────────────────────────────────────────────────────

-- À appeler à chaque tick serveur (uniquement pendant RoundManager.Playing --
-- au Service de le garantir, EntityAI n'a aucune notion de manche). Avance la
-- FSM, applique AU PLUS UNE transition par appel (même philosophie que
-- RoundManager.update), et renvoie le userId frappé CE TICK PRÉCIS, ou nil.
-- Au Service de réagir : appeler PlayerState.applyAttack(userId) si non nil.
function EntityAI.update(self: EntityAI, dt: number, observations: { Types.EntityObservation }): number?
	-- Défensif : dt invalide -> 0 (n'avance pas les timers). observations
	-- invalide (nil/pas une table) -> liste vide (aucun candidat ce tick).
	local delta: number = if type(dt) == "number" and dt > 0 then dt else 0
	local obsList: { Types.EntityObservation } = if type(observations) == "table" then observations else {}

	-- Le cooldown d'attaque décompte EN CONTINU, quelle que soit la phase.
	if self.attackCooldownTimer > 0 then
		self.attackCooldownTimer = math.max(0, self.attackCooldownTimer - delta)
	end

	self.stateTimer += delta

	local phase = self.phase

	if phase == Types.EntityPhase.Patrol then
		local target = selectTarget(obsList)
		if target then
			self:_enterChase(target.userId, target.position)
		end
		return nil

	elseif phase == Types.EntityPhase.Chase then
		local current = findObservation(obsList, self.targetUserId)
		if isTargetGone(current) then
			self:_enterPatrol()
			return nil
		end
		local target = current :: Types.EntityObservation

		if target.visible then
			self.noContactTimer = 0
			if target.position then
				self.lastKnownPosition = target.position
			end
		else
			self.noContactTimer += delta
		end

		if target.visible and target.distance <= GameConfig.Entity.AttackRange then
			self:_enterAttack()
		elseif self.noContactTimer >= GameConfig.Entity.LoseTargetTime then
			self:_enterSearch()
		end
		return nil

	elseif phase == Types.EntityPhase.Search then
		local current = findObservation(obsList, self.targetUserId)
		if isTargetGone(current) then
			self:_enterPatrol()
			return nil
		end

		local reacquired = selectTarget(obsList)
		if reacquired then
			self:_enterChase(reacquired.userId, reacquired.position)
		elseif self.stateTimer >= GameConfig.Entity.SearchDuration then
			self:_enterPatrol()
		end
		return nil

	elseif phase == Types.EntityPhase.Attack then
		local current = findObservation(obsList, self.targetUserId)
		if isTargetGone(current) then
			self:_enterPatrol()
			return nil
		end
		local target = current :: Types.EntityObservation

		if not target.visible or target.distance > GameConfig.Entity.AttackRange then
			self:_enterChase(target.userId, if target.visible then target.position else nil)
			return nil
		end

		if target.position then
			self.lastKnownPosition = target.position
		end

		if self.attackCooldownTimer <= 0 then
			self.attackCooldownTimer = GameConfig.Entity.AttackCooldown
			return target.userId
		end
		return nil
	end

	return nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Requêtes (pures, sans effet de bord)
-- ───────────────────────────────────────────────────────────────────────

-- Snapshot destiné à être lu par le Service (mouvement réel, HUD debug...).
function EntityAI.getState(self: EntityAI): Types.EntityState
	return {
		phase = self.phase,
		targetUserId = self.targetUserId,
		stateTimer = self.stateTimer,
		lastKnownPosition = self.lastKnownPosition,
	}
end

function EntityAI.getPhase(self: EntityAI): Types.EntityPhase
	return self.phase
end

return EntityAI
