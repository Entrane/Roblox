--!strict
-- EchoController — Couche CAPACITÉS de l'Écho (écholocation + Howl + Frenzy).
-- Une instance = un Écho pour une manche. Pilotée à l'IDENTIQUE que la source
-- d'input soit humaine (Remotes) ou IA (futur hook) — décision #1.
--
-- ─── SOURCE D'INPUT ABSTRAITE (forme exacte) ────────────────────────────
-- Pas d'objet-stratégie injecté, pas de callback (même refus que RoundManager :
-- un callback exécuterait du code de Service au milieu d'un calcul). L'input se
-- réduit à une DONNÉE — un Types.AbilityId — et la « source » est simplement QUI
-- appelle requestAbility :
--   - humain : le handler Remote (EchoService) valide l'identité puis appelle
--     echo:requestAbility("Howl") ;
--   - IA (futur) : un hook de décision appelle EXACTEMENT le même requestAbility.
-- requestAbility ne prend NI Player, NI userId, NI flag de source : EchoController
-- ne sait jamais d'où vient l'intention. Toute la logique cooldown/effet vit ici,
-- appelée à l'identique des deux côtés → zéro duplication.
-- L'input CONTINU (écholocation) entre par les `observations` d'update, lui aussi
-- sans marqueur de source.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR : aucune donnée 3D calculée, aucune Instance, aucun réseau. La
-- géométrie (distance Écho→survivant, position) est résolue par le Service et
-- fournie via Types.EntityObservation (MÊME pipeline que pour EntityAI, décision
-- #9 ; le Service réutilise le type en remplissant `position` pour tout survivant
-- dans EcholocationRange — politique de remplissage côté Service, pas ici).
-- PASSIF : EchoController ne notifie personne, n'appelle aucun autre module Logic.
-- Il EXPOSE des sorties (pings retournés par update, vitesse/état en requête) que
-- le Service consomme. Anti-triche : c'est au Service de ne répliquer les pings
-- qu'au SEUL client Écho (décision #9) — jamais à un survivant.
--
-- ─── TROIS SORTIES ──────────────────────────────────────────────────────
--   1. Pings d'écholocation : retour d'update sur tick de PULSE (~2 Hz), nil
--      sinon. Howl les ÉLARGIT (révélation totale), il ne crée pas de canal neuf.
--   2. Vitesse effective : getMoveSpeed(), boostée par Frenzy. Le Service écrit
--      humanoid.WalkSpeed avec, chaque tick (mode humain).
--   3. État HUD : getState() -> Types.EchoState (cooldowns + temps d'effet).
--
-- ─── COMPATIBILITÉ IA (état des lieux) ──────────────────────────────────
-- L'INTERFACE est déjà IA-ready : brancher l'IA ne demandera AUCUNE modif ici
-- (le hook IA appellera requestAbility). C'est EntityAI qui recevra plus tard un
-- petit hook de décision d'usage des capacités. En mode IA, EchoController et
-- EntityAI COEXISTENT (nav = EntityAI, capacités = EchoController) ; les pings y
-- sont non consommés (l'IA « voit » via EntityObservation directement).
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- CHOIX ASSUMÉ — require uniforme (vs injection), voir les modules précédents :
-- GameConfig et Types sont des constantes/types figés. Require ISOLÉS ci-dessous.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local EchoController = {}
EchoController.__index = EchoController

-- État interne. echoTimer = accumulateur du pulse d'écholocation. howl/frenzy
-- sont deux Types.AbilityState INDÉPENDANTS (effets, cooldowns et timers disjoints).
export type EchoController = typeof(setmetatable(
	{} :: {
		echoTimer: number,
		howl: Types.AbilityState,
		frenzy: Types.AbilityState,
	},
	EchoController
))

-- ───────────────────────────────────────────────────────────────────────
-- Helpers privés (purs)
-- ───────────────────────────────────────────────────────────────────────

-- Décompte cooldown ET effet d'une capacité, indépendamment, sans passer sous 0.
local function advanceAbility(a: Types.AbilityState, delta: number)
	if a.cooldownRemaining > 0 then
		a.cooldownRemaining = math.max(0, a.cooldownRemaining - delta)
	end
	if a.activeRemaining > 0 then
		a.activeRemaining = math.max(0, a.activeRemaining - delta)
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

-- Instance autonome (pas de singleton → testable en isolation), identity-agnostic
-- (ne connaît pas l'userId de l'Écho : le Service sait à quel client répliquer).
-- Tout à zéro : aucune capacité en cooldown ni active, pulse non amorcé.
function EchoController.new(): EchoController
	local self = setmetatable({}, EchoController) :: EchoController
	self.echoTimer = 0
	self.howl = { cooldownRemaining = 0, activeRemaining = 0 }
	self.frenzy = { cooldownRemaining = 0, activeRemaining = 0 }
	return self
end

-- ───────────────────────────────────────────────────────────────────────
-- Input abstrait : intention d'activation (humain Remotes / IA future, identique)
-- ───────────────────────────────────────────────────────────────────────

-- Active une capacité SI son cooldown est prêt. Comme Cooldown > Durée pour les
-- deux (Howl 25>3, Frenzy 30>5), un re-déclenchement pendant la fenêtre active est
-- rejeté (cooldownRemaining > 0) → pas de double-activation ni de stacking.
-- abilityId inconnu ou capacité en cooldown → ignoré silencieusement (défensif).
function EchoController.requestAbility(self: EchoController, abilityId: Types.AbilityId)
	if abilityId == Types.AbilityId.Howl then
		if self.howl.cooldownRemaining > 0 then
			return
		end
		self.howl.activeRemaining = GameConfig.Echo.Howl.RevealDuration
		self.howl.cooldownRemaining = GameConfig.Echo.Howl.Cooldown
	elseif abilityId == Types.AbilityId.Frenzy then
		if self.frenzy.cooldownRemaining > 0 then
			return
		end
		self.frenzy.activeRemaining = GameConfig.Echo.Frenzy.Duration
		self.frenzy.cooldownRemaining = GameConfig.Echo.Frenzy.Cooldown
	end
	-- abilityId invalide : aucune branche → aucun effet.
end

-- ───────────────────────────────────────────────────────────────────────
-- update — avance les timers + pulse d'écholocation
-- ───────────────────────────────────────────────────────────────────────

-- À appeler à chaque tick serveur (≈60 Hz) pendant que l'Écho est en jeu (au
-- Service de le garantir). Fait avancer cooldowns/effets EN CONTINU, mais n'ÉMET
-- un jeu de pings que sur un tick de PULSE (≈2 Hz, EcholocationInterval) : retourne
-- alors la liste (possiblement vide → efface les marqueurs périmés côté client),
-- et nil hors pulse. Anti-triche : au Service de ne répliquer qu'au client Écho.
function EchoController.update(self: EchoController, dt: number, observations: { Types.EntityObservation }): { Types.EcholocationPing }?
	-- Défensif : dt invalide → 0 ; observations invalide → liste vide.
	local delta: number = if type(dt) == "number" and dt > 0 then dt else 0
	local obsList: { Types.EntityObservation } = if type(observations) == "table" then observations else {}

	-- Timers de capacités (continus, indépendants du pulse).
	advanceAbility(self.howl, delta)
	advanceAbility(self.frenzy, delta)

	-- Cadence du pulse.
	local interval = GameConfig.Echo.EcholocationInterval
	self.echoTimer += delta
	if self.echoTimer < interval then
		return nil -- pas encore l'heure d'émettre
	end
	-- Report du reliquat ; le modulo absorbe un éventuel gros dt (lag) sans
	-- accumuler un backlog de pulses (seules les positions du moment comptent).
	self.echoTimer %= interval

	-- Calcul du jeu de pings de CE pulse. Howl actif → on ignore la portée
	-- (révélation totale). On ne pingue que les survivants encore pertinents
	-- (Alive/Downed) ET dotés d'une position (défensif : skip si position nil —
	-- le Service est censé la remplir dans la portée, mais on ne fait jamais
	-- confiance aveuglément).
	local pings: { Types.EcholocationPing } = {}
	local howlActive = self.howl.activeRemaining > 0
	local range = GameConfig.Echo.EcholocationRange

	for _, obs in obsList do
		local alive = obs.lifeState == Types.LifeState.Alive or obs.lifeState == Types.LifeState.Downed
		if alive and obs.position ~= nil and (howlActive or obs.distance <= range) then
			table.insert(pings, {
				userId = obs.userId,
				position = obs.position,
			})
		end
	end

	return pings
end

-- ───────────────────────────────────────────────────────────────────────
-- Requêtes (pures, sans effet de bord)
-- ───────────────────────────────────────────────────────────────────────

-- Vitesse effective de l'Écho humain : MoveSpeed, multipliée pendant Frenzy.
-- Le Service écrit humanoid.WalkSpeed avec cette valeur chaque tick. (En mode IA,
-- l'intégration de ce bonus à la nav viendra plus tard ; ici, valeur prête.)
function EchoController.getMoveSpeed(self: EchoController): number
	local multiplier = if self.frenzy.activeRemaining > 0
		then GameConfig.Echo.Frenzy.SpeedMultiplier
		else 1
	return GameConfig.Echo.MoveSpeed * multiplier
end

-- Snapshot des capacités (cooldowns + temps d'effet) pour le HUD du client Écho.
-- Copie défensive : l'appelant ne doit jamais muter l'état interne par référence.
function EchoController.getState(self: EchoController): Types.EchoState
	return {
		howl = {
			cooldownRemaining = self.howl.cooldownRemaining,
			activeRemaining = self.howl.activeRemaining,
		},
		frenzy = {
			cooldownRemaining = self.frenzy.cooldownRemaining,
			activeRemaining = self.frenzy.activeRemaining,
		},
	}
end

return EchoController
