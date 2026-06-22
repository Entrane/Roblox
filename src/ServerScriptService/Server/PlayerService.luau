--!strict
-- PlayerService — Pilote PlayerState (Logic) : l'instancie, le branche aux vrais
-- joueurs/personnages, fait avancer update(dt) à chaque tick serveur, et traduit
-- l'état logique (Alive/Downed/Dead, stamina) en effets RÉELS dans le monde
-- (Humanoid.WalkSpeed, mise à terre, mort).
--
-- ─── PlayerState reste PASSIF (comme RoundManager) ──────────────────────
-- PlayerState ne notifie personne. C'est ICI qu'on détecte les transitions de
-- lifeState, par comparaison avant/après (snapshot par joueur), et qu'on
-- interroge areAllIncapacitated(). Aucun callback côté Logic.
--
-- ─── AUTORITÉ SERVEUR STRICTE ───────────────────────────────────────────
-- Toutes les Remotes n'utilisent QUE le Player fourni par OnServerEvent pour
-- l'IDENTITÉ. Aucun userId reçu du client n'est cru comme identité. Le seul
-- paramètre qui reste (la cible de réanimation) est une DONNÉE, entièrement
-- revalidée serveur : état (PlayerState : cible Downed) ET portée monde (tick).
--
-- ─── COUPLAGE AVEC RoundService (assumé) ────────────────────────────────
-- PlayerService DÉPEND de RoundService. La règle de pureté ne visait que les
-- modules Logic (PlayerState/RoundManager restent purs et ignorants l'un de
-- l'autre) ; les Services sont la couche de câblage et peuvent se requérir. On
-- LIT la phase (reset à l'entrée Playing) et on ÉCRIT via signalAllPlayersDowned().

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(ServerStorage.Logic.PlayerState)
local Types = require(ReplicatedStorage.Shared.Types)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local RoundService = require(script.Parent.RoundService)

local PlayerService = {}

-- Instance UNIQUE partagée (upvalue de module, comme roundManager dans
-- RoundService). Récupérable par les futurs Services via getPlayerState().
local playerState: PlayerState.PlayerState = PlayerState.new()

-- Dernier lifeState observé par CE Service (PlayerState est passif → c'est nous
-- qui détectons les transitions). userId -> PlayerLifeState.
local lastLife: { [number]: Types.PlayerLifeState } = {}

-- Phase précédente observée, pour détecter l'ENTRÉE en Playing (reset de manche).
-- Légère duplication de la comparaison de phase faite par RoundService : c'est le
-- prix du découplage (RoundManager reste passif, pas de callback partagé).
local lastPhase: Types.RoundPhase = RoundService.getRoundManager():getPhase()

-- Front montant de areAllIncapacitated : on ne prévient RoundService qu'UNE fois.
local lastAllIncapacitated = false

-- Intentions de réanimation reçues des clients : rescuerUserId -> targetUserId.
-- Revalidées chaque tick (portée monde) avant d'être transmises à PlayerState.
local reviveIntents: { [number]: number } = {}

local initialized = false

-- ───────────────────────────────────────────────────────────────────────
-- Accès au monde (helpers défensifs : personnage pas chargé / mort retiré)
-- ───────────────────────────────────────────────────────────────────────

-- Humanoid VIVANT du joueur (Health > 0), ou nil. On exige Health > 0 pour que
-- l'application du mouvement ignore naturellement un corps mort/en cours de retrait.
local function getHumanoid(userId: number): Humanoid?
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

-- Position du HumanoidRootPart, ou nil (personnage absent). Sert aux mesures de
-- portée (réanimation) : la SEULE géométrie que ce Service calcule pour l'instant.
local function getRootPosition(userId: number): Vector3?
	local player = Players:GetPlayerByUserId(userId)
	if not player or not player.Character then
		return nil
	end
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Traduction état logique -> monde
-- ───────────────────────────────────────────────────────────────────────

-- Vitesse de marche selon l'état : sprint/marche si Alive, immobile sinon.
-- La DÉCISION du sprint vit entièrement dans PlayerState (validé Alive +
-- stamina >= MinToStartSprint, coupé à 0) ; ici on ne fait que LIRE isSprinting.
local function applyMovement(userId: number, snapshot: Types.PlayerState)
	local humanoid = getHumanoid(userId)
	if not humanoid then
		return
	end
	if snapshot.lifeState == Types.LifeState.Alive then
		humanoid.WalkSpeed = if snapshot.isSprinting
			then GameConfig.Player.SprintSpeed
			else GameConfig.Player.WalkSpeed
	else
		humanoid.WalkSpeed = 0
	end
end

-- Mise à terre v1 (PAS de ragdoll par constraints — décision assumée, suivi
-- ultérieur). PlatformStand retire tout contrôle (déplacement ET saut, sans
-- toucher à JumpPower) et fait basculer le personnage. La caméra reste attachée :
-- le joueur à terre continue de VOIR la scène — c'est la tension de l'attente
-- de réanimation.
local function enterDowned(userId: number)
	local humanoid = getHumanoid(userId)
	if not humanoid then
		return
	end
	humanoid.WalkSpeed = 0
	humanoid.PlatformStand = true
end

-- Sortie de l'état à terre (réanimation réussie : Downed -> Alive). On rend le
-- contrôle ; le tick suivant restaurera WalkSpeed via applyMovement.
local function exitDowned(userId: number)
	local humanoid = getHumanoid(userId)
	if not humanoid then
		return
	end
	humanoid.PlatformStand = false
end

-- Mort réelle. CharacterAutoLoads = false (posé à l'init) → pas de respawn : le
-- joueur reste mort/spectateur jusqu'au reset de manche (entrée Playing).
local function enterDead(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if not player or not player.Character then
		return
	end
	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = 0
	end
end

local function onLifeStateChanged(userId: number, previous: Types.PlayerLifeState, current: Types.PlayerLifeState)
	-- Trace permanente (pas de HUD encore) : seul endroit qui détecte ces
	-- transitions, utile au debug en Studio.
	print(string.format("[PlayerService] Joueur %d : %s -> %s", userId, previous, current))

	if current == Types.LifeState.Downed then
		enterDowned(userId)
	elseif current == Types.LifeState.Alive then
		exitDowned(userId) -- depuis Downed (réanimation)
	elseif current == Types.LifeState.Dead then
		enterDead(userId)
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Réanimation : conditions DE MONDE revalidées chaque tick
-- ───────────────────────────────────────────────────────────────────────

-- PlayerState n'expose pas QUI tient la réanimation (revivingBy est interne).
-- On pilote donc setReviving/stopReviving uniquement à partir des intentions
-- clients filtrées par la portée monde :
--   - cible tenue en portée par >=1 sauveteur intentionnel -> setReviving
--     (PlayerState applique « premier arrivé » et ignore les doublons) ;
--   - cible en cours de réanimation mais PLUS tenue en portée -> stopReviving.
-- Limite connue (API publique) : si le PORTEUR de la réanimation sort de portée
-- alors qu'un AUTRE sauveteur intentionnel reste en portée, la progression se
-- poursuit (un coéquipier est là) — comportement acceptable et même souhaitable.
local function resolveRevives()
	local heldTargets: { [number]: number } = {} -- targetId -> un rescuerId en portée

	for rescuerId, targetId in reviveIntents do
		local rescuerPos = getRootPosition(rescuerId)
		local targetPos = getRootPosition(targetId)
		if rescuerPos and targetPos and (rescuerPos - targetPos).Magnitude <= GameConfig.Revive.Distance then
			heldTargets[targetId] = rescuerId
		end
	end

	for targetId, rescuerId in heldTargets do
		playerState:setReviving(targetId, rescuerId) -- état revalidé dans PlayerState
	end

	-- Annule toute réanimation entamée mais qui n'est plus tenue en portée.
	for targetId, snapshot in playerState:getAllStates() do
		if snapshot.reviveProgress > 0 and not heldTargets[targetId] then
			playerState:stopReviving(targetId)
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Reset de manche (entrée en Playing)
-- ───────────────────────────────────────────────────────────────────────

-- registerPlayer est idempotent : il ne RÉINITIALISE pas un joueur déjà inscrit.
-- À l'entrée en Playing, on force donc un état frais (Alive, stamina/batterie
-- pleines) via remove + register, et on redonne un corps neuf à qui est mort /
-- sans personnage. NB : RoundService téléporte de son côté les corps existants
-- au SpawnPoint sur cette même transition ; un corps fraîchement rechargé ici
-- apparaît au SpawnLocation par défaut (couture à revisiter avec l'entité et le
-- multijoueur — cas rare aujourd'hui).
local function onPlayingStarted()
	for _, player in Players:GetPlayers() do
		local userId = player.UserId
		playerState:removePlayer(userId)
		playerState:registerPlayer(userId)
		lastLife[userId] = Types.LifeState.Alive
		reviveIntents[userId] = nil
		if not getHumanoid(userId) then
			player:LoadCharacter()
		end
	end
	lastAllIncapacitated = false
end

local function resolvePhase()
	local phase = RoundService.getRoundManager():getPhase()
	if phase ~= lastPhase then
		if phase == Types.RoundPhase.Playing then
			onPlayingStarted()
		end
		lastPhase = phase
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Condition de défaite collective
-- ───────────────────────────────────────────────────────────────────────

-- Front montant uniquement : on prévient RoundService une seule fois quand plus
-- aucun joueur n'est Alive. (En aval, onRoundResolved est de toute façon gardé
-- Playing ; areAllIncapacitated est false tant qu'un joueur est Alive.)
local function resolveDefeatCondition()
	local allDown = playerState:areAllIncapacitated()
	if allDown and not lastAllIncapacitated then
		RoundService.signalAllPlayersDowned()
	end
	lastAllIncapacitated = allDown
end

-- ───────────────────────────────────────────────────────────────────────
-- Tick serveur
-- ───────────────────────────────────────────────────────────────────────

local function tick(dt: number)
	-- 1) Reset éventuel à l'entrée en Playing (lecture de la phase RoundService).
	resolvePhase()

	-- 2) Intentions de réanimation -> conditions monde -> PlayerState, AVANT
	--    update pour que la progression avance dès ce tick.
	resolveRevives()

	-- 3) Avance la logique pure (stamina / batterie / réanimation / saignement).
	playerState:update(dt)

	-- 4) Détection des transitions de lifeState (PlayerState passif) + traduction
	--    de l'état en effets monde (WalkSpeed selon stamina).
	for _, player in Players:GetPlayers() do
		local userId = player.UserId
		local snapshot = playerState:getState(userId)
		if snapshot then
			local previous = lastLife[userId]
			if previous ~= nil and previous ~= snapshot.lifeState then
				onLifeStateChanged(userId, previous, snapshot.lifeState)
			end
			lastLife[userId] = snapshot.lifeState
			applyMovement(userId, snapshot)
		end
	end

	-- 5) Défaite collective (front montant -> RoundService).
	resolveDefeatCondition()
end

-- ───────────────────────────────────────────────────────────────────────
-- Joueurs / personnages
-- ───────────────────────────────────────────────────────────────────────

-- Resynchronise un corps fraîchement apparu (spawn/respawn) sur l'état logique :
-- applique la vitesse, et remet la mise à terre si le joueur est encore Downed.
local function onCharacterAdded(userId: number, _character: Model)
	local snapshot = playerState:getState(userId)
	if not snapshot then
		return
	end
	applyMovement(userId, snapshot)
	if snapshot.lifeState == Types.LifeState.Downed then
		enterDowned(userId)
	end
end

local function registerPlayer(player: Player)
	local userId = player.UserId
	playerState:registerPlayer(userId)
	lastLife[userId] = Types.LifeState.Alive

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(userId, character)
	end)
	if player.Character then
		onCharacterAdded(userId, player.Character)
	end

	-- CharacterAutoLoads est désactivé (init) : on déclenche nous-mêmes le spawn.
	player:LoadCharacter()
end

local function removePlayer(player: Player)
	local userId = player.UserId
	playerState:removePlayer(userId)
	lastLife[userId] = nil
	reviveIntents[userId] = nil
	-- Nettoie aussi les intentions qui CIBLAIENT ce joueur.
	for rescuerId, targetId in reviveIntents do
		if targetId == userId then
			reviveIntents[rescuerId] = nil
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Remotes (client -> serveur) — AUTORITÉ SERVEUR STRICTE
-- ───────────────────────────────────────────────────────────────────────

-- Identité = TOUJOURS `player` (fourni par OnServerEvent), jamais un userId du
-- client. Les charges utiles sont validées par type avant transmission.
local function onSetSprinting(player: Player, wants: unknown)
	if type(wants) ~= "boolean" then
		return
	end
	playerState:setSprinting(player.UserId, wants)
end

local function onSetTorch(player: Player, on: unknown)
	if type(on) ~= "boolean" then
		return
	end
	playerState:setTorch(player.UserId, on)
end

-- Sauveteur = player (identité serveur). Cible = DONNÉE client, simplement
-- enregistrée ici puis revalidée chaque tick (état + portée) par resolveRevives.
local function onSetReviving(player: Player, targetUserId: unknown)
	if type(targetUserId) ~= "number" then
		return
	end
	reviveIntents[player.UserId] = targetUserId
end

local function onStopReviving(player: Player)
	reviveIntents[player.UserId] = nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Interface publique
-- ───────────────────────────────────────────────────────────────────────

-- Lecture : pas de wrappers. Les futurs Services lisent via l'API publique de
-- PlayerState (getState/getAllStates/areAllIncapacitated) sur l'instance rendue.
function PlayerService.getPlayerState(): PlayerState.PlayerState
	return playerState
end

-- Écriture ciblée : EntityService inflige les dégâts sans connaître l'API exacte.
function PlayerService.applyAttack(userId: number)
	playerState:applyAttack(userId)
end

-- Écriture ciblée : un pickup de pile (FuseService/interaction) recharge la torche.
function PlayerService.recharge(userId: number)
	playerState:recharge(userId)
end

-- Point d'entrée unique. Appelé une seule fois par init.server.luau, APRÈS
-- RoundService.init() (on lit sa phase et on l'appelle).
function PlayerService.init()
	if initialized then
		return
	end
	initialized = true

	-- On gère le spawn nous-mêmes : un mort reste mort jusqu'au reset de manche.
	Players.CharacterAutoLoads = false

	for _, player in Players:GetPlayers() do
		registerPlayer(player)
	end
	Players.PlayerAdded:Connect(registerPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	Remotes.SetSprinting.OnServerEvent:Connect(onSetSprinting)
	Remotes.SetTorch.OnServerEvent:Connect(onSetTorch)
	Remotes.SetReviving.OnServerEvent:Connect(onSetReviving)
	Remotes.StopReviving.OnServerEvent:Connect(onStopReviving)

	RunService.Heartbeat:Connect(tick)
end

return PlayerService
