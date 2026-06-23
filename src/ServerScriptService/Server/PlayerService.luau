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
-- ─── COUPLAGES SERVICE (assumés) ────────────────────────────────────────
-- PlayerService DÉPEND de RoundService (LIT la phase ; ÉCRIT le vainqueur via
-- signalRoundResolved) et d'EchoService (LIT getRoleManager():getEchoUserId()
-- pour EXCLURE l'Écho du registre survivant). La règle de pureté ne visait que
-- les modules Logic ; les Services sont la couche de câblage et peuvent se
-- requérir. EchoService est requis LAZY (cf. onPlayingStarted) pour éviter un
-- cycle de require (EchoService require déjà PlayerService au chargement).
-- PlayerService est désormais le SEUL calculateur du vainqueur (décision #4).

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

-- Front montant de la résolution de fin : on ne signale le vainqueur qu'UNE fois.
-- Remis à false au démarrage (onPlayingStarted) ET au teardown (onPlayingEnded).
local lastResolved = false

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
	-- require LAZY d'EchoService : il require déjà PlayerService au chargement, le
	-- requérir au top créerait un cycle. Ici (manche qui démarre, bien après
	-- l'init), EchoService est chargé/caché → require instantané. L'ordre des
	-- Heartbeat (RoundService → EchoService → PlayerService) garantit qu'EchoService
	-- a DÉJÀ posé echoUserId via assignRoles sur cette même frame.
	local EchoService = require(script.Parent.EchoService)
	local echoId = EchoService.getRoleManager():getEchoUserId() -- nil en mode IA

	for _, player in Players:GetPlayers() do
		local userId = player.UserId
		-- Purge TOUJOURS (résidu d'une manche précédente, y compris si ce joueur
		-- était l'Écho avant et survivant maintenant, ou l'inverse).
		playerState:removePlayer(userId)
		reviveIntents[userId] = nil
		lastLife[userId] = nil

		-- EXCLUSION DE L'ÉCHO : on n'inscrit PAS le joueur Écho (son corps/spawn/
		-- vitesse sont gérés par EchoService). En mode IA, echoId == nil → aucun
		-- match → tout le monde est inscrit, comme avant l'arrivée du PvP.
		if userId ~= echoId then
			playerState:registerPlayer(userId)
			lastLife[userId] = Types.LifeState.Alive
			if not getHumanoid(userId) then
				player:LoadCharacter()
			end
		end
	end
	lastResolved = false
end

-- Sortie de Playing : reset EXPLICITE du front montant de résolution (et non
-- supposé via le garde de resolveRoundResolution). Garantit un état propre entre
-- les manches.
local function onPlayingEnded()
	lastResolved = false
end

local function resolvePhase()
	local phase = RoundService.getRoundManager():getPhase()
	if phase ~= lastPhase then
		if phase == Types.RoundPhase.Playing then
			onPlayingStarted()
		elseif lastPhase == Types.RoundPhase.Playing then
			onPlayingEnded()
		end
		lastPhase = phase
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Résolution de fin de manche — SEUL calculateur du vainqueur (décision #4)
-- ───────────────────────────────────────────────────────────────────────

-- PlayerService centralise le calcul du vainqueur (RoundService ne nomme plus
-- aucune faction). PRIORITÉ : la résolution survivants est testée AVANT le
-- timeout → la victoire gagne la course au temps (l'idempotence de
-- onRoundResolved verrouille le premier de toute façon). Le timeout, DÉPLACÉ ici
-- depuis RoundService, favorise l'Écho (temps écoulé).
local function resolveRoundResolution()
	local roundManager = RoundService.getRoundManager()
	if roundManager:getPhase() ~= Types.RoundPhase.Playing then
		return -- hors Playing : onPlayingEnded gère le reset de lastResolved
	end

	-- 1) Tous les survivants résolus (Dead OU Escaped) → fin. Front montant pour
	--    ne signaler qu'une fois ; ≥ 1 évadé → Survivors, sinon (tous Dead) → Echo.
	if playerState:areAllSurvivorsResolved() then
		if not lastResolved then
			local winner = if playerState:hasAnyEscaped()
				then Types.Faction.Survivors
				else Types.Faction.Echo
			RoundService.signalRoundResolved(winner)
			lastResolved = true
		end
		return
	end

	-- 2) Sinon, garde-fou de durée écoulé → l'Écho l'emporte.
	if roundManager:getState().timeRemaining <= 0 then
		RoundService.signalRoundResolved(Types.Faction.Echo)
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Tick serveur
-- ───────────────────────────────────────────────────────────────────────

-- Réplication HUD : PlayerHud poussé à CHAQUE survivant inscrit (son propre
-- état), throttlé. L'Écho n'est pas inscrit → ne reçoit jamais PlayerHud.
local HUD_INTERVAL = 0.1 -- s (~10 Hz)
local hudAccum = 0

local function tick(dt: number)
	-- 1) Reset éventuel à l'entrée en Playing (lecture de la phase RoundService).
	resolvePhase()

	-- 2) Intentions de réanimation -> conditions monde -> PlayerState, AVANT
	--    update pour que la progression avance dès ce tick.
	resolveRevives()

	-- 3) Avance la logique pure (stamina / batterie / réanimation / saignement).
	playerState:update(dt)

	-- HUD : fenêtre de push throttlée, calculée une fois pour toute la boucle.
	hudAccum += dt
	local pushHud = hudAccum >= HUD_INTERVAL
	if pushHud then
		hudAccum -= HUD_INTERVAL
	end

	-- 4) Détection des transitions de lifeState (PlayerState passif) + traduction
	--    de l'état en effets monde (WalkSpeed selon stamina). + push HUD par survivant.
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

			-- PlayerHud : seulement le SIEN (FireClient), charge minimale.
			if pushHud then
				Remotes.PlayerHud:FireClient(player, {
					stamina = snapshot.stamina,
					battery = snapshot.battery,
					lifeState = snapshot.lifeState,
				})
			end
		end
	end

	-- 5) Résolution de fin de manche (vainqueur calculé ICI, décision #4).
	resolveRoundResolution()
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

-- Écriture ciblée : FuseService déclenche l'évasion d'un survivant atteignant la
-- sortie. markEscaped est gardé Alive côté PlayerState (Downed/Dead/Escaped →
-- no-op). C'est le maillon qui alimente resolveRoundResolution (areAllSurvivorsResolved
-- / hasAnyEscaped → victoire Survivors).
function PlayerService.markEscaped(userId: number)
	playerState:markEscaped(userId)
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
