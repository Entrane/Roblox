--!strict
-- PlayerState — Registre de l'état logique de tous les joueurs d'une manche.
-- Chaque entrée suit un cycle Alive → Downed → (Dead | Alive), plus la stamina,
-- la batterie de torche et la réanimation.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR : aucune donnée 3D, aucune distance, aucune ligne de vue. Tout
-- événement du monde (attaque, départ, sauveteur en portée…) ENTRE par appel de
-- fonction ; les vérifications spatiales restent au Service.
--
-- PASSIF, comme RoundManager : il ne notifie personne et n'appelle aucun autre
-- module Logic. La détection « tous à terre » est exposée en REQUÊTE
-- (areAllIncapacitated) ; c'est le Service qui interroge et, le cas échéant,
-- prévient RoundManager. Frontière : PlayerState = vérité d'état + requête ;
-- Service = câblage ; RoundManager = décision.
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- CHOIX ASSUMÉ — require uniforme (vs injection), voir RoundManager : GameConfig
-- et Types sont des constantes/types figés. Les require sont ISOLÉS dans l'unique
-- bloc ci-dessous pour qu'un futur passage à l'injection reste chirurgical.
-- ⚠️ À VALIDER DANS STUDIO : chemin require ReplicatedStorage.Shared.* et typage
-- strict du pattern OOP typeof(setmetatable(...)).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local PlayerState = {}
PlayerState.__index = PlayerState

-- Entrée interne = sur-ensemble de Types.PlayerState. Les champs marqués
-- « interne » NE SONT PAS répliqués (getState ne renvoie que le contrat Types).
type Record = {
	-- Champs répliqués (= Types.PlayerState)
	userId: number,
	lifeState: Types.PlayerLifeState,
	stamina: number,
	battery: number,
	isSprinting: boolean,
	torchOn: boolean,
	reviveProgress: number,
	-- Champs internes
	regenCooldown: number, -- délai restant (s) avant reprise de la régén stamina
	bleedOutTimer: number, -- temps écoulé (s) à l'état Downed
	revivingBy: number?, -- userId du sauveteur tenant la réanimation, ou nil
}

export type PlayerState = typeof(setmetatable(
	{} :: {
		players: { [number]: Record },
	},
	PlayerState
))

-- ───────────────────────────────────────────────────────────────────────
-- Helpers privés (purs, sur un Record)
-- ───────────────────────────────────────────────────────────────────────

-- Annule toute réanimation en cours sur ce Record (reset propre).
local function resetRevive(rec: Record)
	rec.reviveProgress = 0
	rec.revivingBy = nil
end

-- Le joueur lâche son équipement (sprint + torche) — sur Downed/Dead.
local function dropEquipment(rec: Record)
	rec.isSprinting = false
	rec.torchOn = false
	rec.regenCooldown = GameConfig.Stamina.RegenDelay
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction & gestion du registre
-- ───────────────────────────────────────────────────────────────────────

function PlayerState.new(): PlayerState
	local self = setmetatable({}, PlayerState) :: PlayerState
	self.players = {}
	return self
end

-- Inscrit un joueur avec un état frais Alive (début de Playing). Idempotent :
-- un userId déjà inscrit n'est pas réinitialisé.
function PlayerState.registerPlayer(self: PlayerState, userId: number)
	if type(userId) ~= "number" then
		return
	end
	if self.players[userId] then
		return
	end
	self.players[userId] = {
		userId = userId,
		lifeState = Types.LifeState.Alive,
		stamina = GameConfig.Stamina.Max,
		battery = GameConfig.Torch.BatteryMax,
		isSprinting = false,
		torchOn = false,
		reviveProgress = 0,
		regenCooldown = 0,
		bleedOutTimer = 0,
		revivingBy = nil,
	}
end

-- Retire un joueur (départ / reset de manche). Inconnu → ignoré.
function PlayerState.removePlayer(self: PlayerState, userId: number)
	if type(userId) ~= "number" then
		return
	end
	self.players[userId] = nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Événements entrants
-- ───────────────────────────────────────────────────────────────────────

-- Attaque de l'entité : Alive → Downed (démarre le saignement) ; Downed → Dead
-- (l'entité achève) ; Dead → ignoré. Joueur inconnu → ignoré.
function PlayerState.applyAttack(self: PlayerState, userId: number)
	if type(userId) ~= "number" then
		return
	end
	local rec = self.players[userId]
	if not rec then
		return
	end

	if rec.lifeState == Types.LifeState.Alive then
		rec.lifeState = Types.LifeState.Downed
		rec.bleedOutTimer = 0
		dropEquipment(rec)
		resetRevive(rec)
	elseif rec.lifeState == Types.LifeState.Downed then
		rec.lifeState = Types.LifeState.Dead
		dropEquipment(rec)
		resetRevive(rec)
	end
	-- Dead : aucun effet.
end

-- Demande de sprint. Autorisé seulement si Alive et stamina >= MinToStartSprint
-- (anti « sprint clignotant »). Couper le sprint démarre le délai de régén.
function PlayerState.setSprinting(self: PlayerState, userId: number, wants: boolean)
	if type(userId) ~= "number" then
		return
	end
	local rec = self.players[userId]
	if not rec or rec.lifeState ~= Types.LifeState.Alive then
		return
	end

	if wants then
		if rec.stamina >= GameConfig.Stamina.MinToStartSprint then
			rec.isSprinting = true
		end
	else
		if rec.isSprinting then
			rec.isSprinting = false
			rec.regenCooldown = GameConfig.Stamina.RegenDelay
		end
	end
end

-- Allume/éteint la torche. Allumer exige Alive et batterie > 0.
function PlayerState.setTorch(self: PlayerState, userId: number, on: boolean)
	if type(userId) ~= "number" then
		return
	end
	local rec = self.players[userId]
	if not rec or rec.lifeState ~= Types.LifeState.Alive then
		return
	end

	if on then
		if rec.battery > 0 then
			rec.torchOn = true
		end
	else
		rec.torchOn = false
	end
end

-- Pile ramassée : recharge la batterie (plafonnée). Joueur mort → ignoré.
function PlayerState.recharge(self: PlayerState, userId: number)
	if type(userId) ~= "number" then
		return
	end
	local rec = self.players[userId]
	if not rec or rec.lifeState == Types.LifeState.Dead then
		return
	end
	rec.battery = math.min(GameConfig.Torch.BatteryMax, rec.battery + GameConfig.Torch.RechargeOnPickup)
end

-- Démarre/maintient une réanimation. Le Service l'appelle quand les conditions
-- DE MONDE sont réunies (sauveteur en portée, maintient l'interaction).
-- PlayerState valide les conditions D'ÉTAT et applique la règle « premier arrivé » :
--  - revivingBy == nil          → le sauveteur prend la main ;
--  - revivingBy == ce sauveteur → on continue (idempotent, pas de reset) ;
--  - revivingBy == un autre     → ignoré (le premier garde la main).
function PlayerState.setReviving(self: PlayerState, targetId: number, rescuerId: number)
	if type(targetId) ~= "number" or type(rescuerId) ~= "number" then
		return
	end
	if targetId == rescuerId then
		return -- on ne se réanime pas soi-même
	end

	local target = self.players[targetId]
	local rescuer = self.players[rescuerId]
	-- Conditions d'état : cible Downed, sauveteur présent et Alive.
	if not target or target.lifeState ~= Types.LifeState.Downed then
		return
	end
	if not rescuer or rescuer.lifeState ~= Types.LifeState.Alive then
		return
	end

	if target.revivingBy == nil then
		target.revivingBy = rescuerId -- prise de la main
	end
	-- Si déjà tenu (par ce sauveteur ou un autre) : aucun changement, aucun reset.
end

-- Annule une réanimation (condition DE MONDE rompue : hors portée, relâche).
-- Cible inconnue ou non réanimée → no-op.
function PlayerState.stopReviving(self: PlayerState, targetId: number)
	if type(targetId) ~= "number" then
		return
	end
	local target = self.players[targetId]
	if not target then
		return
	end
	resetRevive(target)
end

-- ───────────────────────────────────────────────────────────────────────
-- update — avance stamina / batterie / réanimation / saignement
-- ───────────────────────────────────────────────────────────────────────

-- À appeler à chaque tick serveur. ORDRE PAR JOUEUR (documenté car il porte des
-- choix de design) :
--   1) Stamina   2) Batterie   3) RÉANIMATION   4) SAIGNEMENT
-- La réanimation (3) est résolue AVANT le saignement (4) et le saignement n'agit
-- que si le joueur est ENCORE Downed → en cas d'égalité au même tick, la
-- RÉANIMATION GAGNE (même philosophie que « victoire gagne le timeout »).
function PlayerState.update(self: PlayerState, dt: number)
	-- Défensif : dt invalide (nil/NaN/≤0) → 0 (on n'avance pas les timers).
	local delta: number = if type(dt) == "number" and dt > 0 then dt else 0

	local staminaCfg = GameConfig.Stamina
	local torchCfg = GameConfig.Torch
	local reviveCfg = GameConfig.Revive

	for _, rec in self.players do
		-- 1) STAMINA
		if rec.isSprinting then
			rec.stamina -= staminaCfg.DrainPerSecond * delta
			if rec.stamina <= 0 then
				rec.stamina = 0
				rec.isSprinting = false
				rec.regenCooldown = staminaCfg.RegenDelay -- épuisement → délai de régén
			end
		else
			if rec.regenCooldown > 0 then
				rec.regenCooldown -= delta
			elseif rec.stamina < staminaCfg.Max then
				rec.stamina = math.min(staminaCfg.Max, rec.stamina + staminaCfg.RegenPerSecond * delta)
			end
		end

		-- 2) BATTERIE
		if rec.torchOn and rec.battery > 0 then
			rec.battery -= torchCfg.DrainPerSecond * delta
			if rec.battery <= 0 then
				rec.battery = 0
				rec.torchOn = false -- batterie vide → torche coupée
			end
		end

		-- 3) RÉANIMATION (AVANT le saignement)
		if rec.lifeState == Types.LifeState.Downed and rec.revivingBy ~= nil then
			local rescuer = self.players[rec.revivingBy]
			-- Re-vérification d'état : sauveteur INTROUVABLE (removePlayer) ou plus
			-- Alive → annulation propre, jamais une erreur (cas limite c).
			if not rescuer or rescuer.lifeState ~= Types.LifeState.Alive then
				resetRevive(rec)
			else
				rec.reviveProgress += delta
				if rec.reviveProgress >= reviveCfg.Duration then
					-- Réanimation réussie : retour Alive, stamina partielle « groggy ».
					rec.lifeState = Types.LifeState.Alive
					rec.stamina = staminaCfg.Max * reviveCfg.StaminaOnRevive
					rec.bleedOutTimer = 0
					resetRevive(rec)
				end
			end
		end

		-- 4) SAIGNEMENT (APRÈS) — seulement si TOUJOURS Downed
		if rec.lifeState == Types.LifeState.Downed then
			rec.bleedOutTimer += delta
			if rec.bleedOutTimer >= reviveCfg.BleedOutTime then
				rec.lifeState = Types.LifeState.Dead
				dropEquipment(rec)
				resetRevive(rec)
			end
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Requêtes (pures, sans effet de bord)
-- ───────────────────────────────────────────────────────────────────────

-- Vrai SSI ≥ 1 joueur suivi ET aucun joueur Alive (plus personne ne peut
-- réanimer → situation irrécupérable). 0 joueur → false (géré par RoundManager).
function PlayerState.areAllIncapacitated(self: PlayerState): boolean
	local total = 0
	local alive = 0
	for _, rec in self.players do
		total += 1
		if rec.lifeState == Types.LifeState.Alive then
			alive += 1
		end
	end
	return total > 0 and alive == 0
end

-- Projette le Record interne vers le contrat répliqué Types.PlayerState
-- (sans les champs internes). nil si joueur inconnu.
function PlayerState.getState(self: PlayerState, userId: number): Types.PlayerState?
	local rec = self.players[userId]
	if not rec then
		return nil
	end
	return {
		userId = rec.userId,
		lifeState = rec.lifeState,
		stamina = rec.stamina,
		battery = rec.battery,
		isSprinting = rec.isSprinting,
		torchOn = rec.torchOn,
		reviveProgress = rec.reviveProgress,
	}
end

-- Snapshot de tous les joueurs (réplication HUD).
function PlayerState.getAllStates(self: PlayerState): { [number]: Types.PlayerState }
	local out: { [number]: Types.PlayerState } = {}
	for userId in self.players do
		local snap = self:getState(userId)
		if snap then
			out[userId] = snap
		end
	end
	return out
end

return PlayerState
