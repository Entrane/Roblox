--!strict
-- EchoService — Incarnation de l'Écho (humain OU IA) et autorité des rôles.
-- POSSÈDE le RoleManager (décision A) : il le pilote (présence, assignRoles au
-- démarrage de manche) et l'expose via getRoleManager() pour PlayerService (6c).
-- Selon le mode figé au démarrage, il pilote soit un joueur Écho humain
-- (capacités via EchoController + écholocation répliquée à lui seul), soit l'IA
-- (EntityAI navigation + frappe).
--
-- ⚠️ NON EXÉCUTABLE HORS STUDIO : glue lourdement API Roblox (Humanoid, Raycast,
-- FireClient, CharacterAdded, déplacement de corps). La logique pure décisionnelle
-- vit déjà dans EchoController/EntityAI/RoleManager (shim-testés). Ici on ne
-- vérifie que la cohérence de types (luau-analyze) ; le comportement est à
-- valider en Studio. Toutes les hypothèses Roblox sont marquées ⚠️.
--
-- ─── ANTI-TRICHE (décision #9) ──────────────────────────────────────────
-- L'écholocation (Echolocation) et l'état des capacités (EchoState) ne sont émis
-- qu'au SEUL client Écho, via FireClient(echoPlayer, …), JAMAIS FireAllClients.
-- La donnée (positions des survivants) ne quitte jamais le serveur pour un autre
-- client. ActivateAbility est revalidé : seul le joueur Écho courant est accepté
-- (identité = Player de OnServerEvent, jamais un userId du client).
--
-- ─── COUPLAGES (assumés, runtime uniquement) ────────────────────────────
-- EchoService LIT PlayerService.getPlayerState() (états survivants) et appelle
-- PlayerService.applyAttack() (mode IA) ; en 6c, PlayerService lira en retour
-- EchoService.getRoleManager(). Mutuel mais UNIQUEMENT au tick, jamais au
-- chargement → sûr (même discipline que RoundService↔PlayerService).
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- require uniforme des modules Logic/partagés, ISOLÉS dans le bloc ci-dessous.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoleManager = require(ServerStorage.Logic.RoleManager)
local EchoController = require(ServerStorage.Logic.EchoController)
local EntityAI = require(ServerStorage.Logic.EntityAI)
local RateLimiter = require(ServerStorage.Logic.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local SoundConfig = require(ReplicatedStorage.Shared.SoundConfig)
local RoundService = require(script.Parent.RoundService)
local PlayerService = require(script.Parent.PlayerService)

local EchoService = {}

-- Mode courant de l'Écho. nil hors Playing.
type Mode = "Human" | "AI"

-- Politique de remplissage de `position` dans les observations (cf. §4 de
-- l'explication) : "sonar" = position TOUJOURS remplie (écholocation traverse
-- les murs) ; "onContact" = seulement si visible/audible (gating EntityAI).
type FillPolicy = "sonar" | "onContact"

-- ───────────────────────────────────────────────────────────────────────
-- État de module (RoleManager permanent ; le reste est PAR MANCHE)
-- ───────────────────────────────────────────────────────────────────────

local roleManager: RoleManager.RoleManager = RoleManager.new()

local echoController: EchoController.EchoController? = nil
local entityAI: EntityAI.EntityAI? = nil
local mode: Mode? = nil
local echoUserId: number? = nil

-- Cooldown de mêlée de l'Écho HUMAIN (séparé du cooldown IA, géré dans EntityAI).
-- Sentinelle très négative → première attaque toujours autorisée. Reset au démarrage.
local lastMeleeAt = -1e9

-- Dernière position connue de l'Écho HUMAIN, mise à jour CHAQUE tick humain.
-- Sert de point d'apparition à l'entité IA si l'Écho humain quitte en cours de
-- manche : on NE LIT PAS le HumanoidRootPart au moment de la bascule (il peut
-- déjà avoir disparu pendant PlayerRemoving) — on réutilise cette valeur
-- capturée AVANT le teardown. ⚠️ À VALIDER DANS STUDIO (continuité visuelle).
local lastEchoPosition: Vector3? = nil

local lastPhase: Types.RoundPhase = RoundService.getRoundManager():getPhase()
local missingEntityWarned = false
local initialized = false

-- Anti-flood des Remotes Écho (garde EXTERNE générique, complémentaire des
-- cooldowns de gameplay déjà présents dans EchoController/onMeleeAttack). Un
-- token bucket par (joueur, Remote). IS_STUDIO gate le warn (une fois par rafale).
local rateLimiter: RateLimiter.RateLimiter = RateLimiter.new()
local IS_STUDIO = RunService:IsStudio()

-- ───────────────────────────────────────────────────────────────────────
-- Helpers monde (défensifs : perso pas chargé / corps retiré)
-- ───────────────────────────────────────────────────────────────────────

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

-- Corps de l'entité IA. ⚠️ À VALIDER DANS STUDIO : on suppose un modèle
-- Workspace.Entity avec un HumanoidRootPart. Le modèle/pathfinding est un travail
-- d'asset Studio (hors périmètre code) : absent → on prévient une fois et l'IA
-- n'agit pas ce tick (la manche continue : timer/évasions restent possibles).
local function getEntityRoot(): BasePart?
	local model = Workspace:FindFirstChild("Entity")
	if not model then
		if not missingEntityWarned then
			warn("[EchoService] Workspace.Entity introuvable : l'Écho IA n'agit pas. ⚠️ asset Studio à créer.")
			missingEntityWarned = true
		end
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Géométrie (⚠️ uniquement pour le mode IA / politique "onContact")
-- ───────────────────────────────────────────────────────────────────────

-- Ligne de vue dégagée de `fromPos` vers le personnage `targetChar` : raycast
-- qui ignore l'observateur ; visible si rien n'obstrue avant la cible.
-- ⚠️ À VALIDER DANS STUDIO : le cône de vision (SightAngle) et le filtrage fin
-- des parts ne sont PAS encore gérés ici (orientation fiable de l'entité requise) ;
-- première approximation occlusion seule. À compléter à l'étape entité.
local function isLineClear(fromPos: Vector3, targetChar: Instance, targetPos: Vector3, ignore: { Instance }): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local direction = targetPos - fromPos
	local result = Workspace:Raycast(fromPos, direction, params)
	if not result then
		return true -- rien touché : dégagé
	end
	return result.Instance:IsDescendantOf(targetChar) -- on a touché la cible elle-même
end

-- Construit la liste d'observations référencée à `observerPos`. `fillPolicy`
-- décide du remplissage de `position` (cf. types). Les survivants = tous les
-- inscrits de PlayerState (l'Écho n'y est pas, exclusion 6c).
local function buildObservations(observerPos: Vector3, fillPolicy: FillPolicy, ignore: { Instance }): { Types.EntityObservation }
	local out: { Types.EntityObservation } = {}
	local playerState = PlayerService.getPlayerState()

	for userId, snap in playerState:getAllStates() do
		local player = Players:GetPlayerByUserId(userId)
		local survPos = getRootPosition(userId)
		if player and player.Character and survPos then
			local distance = (survPos - observerPos).Magnitude

			local visible = false
			local audible = false
			if fillPolicy == "onContact" then
				-- ⚠️ géométrie IA, première approximation (cf. isLineClear).
				if distance <= GameConfig.Entity.SightRange then
					visible = isLineClear(observerPos, player.Character, survPos, ignore)
				end
				-- Le sprint fait du bruit dans HearRange (snap lu dans PlayerState).
				audible = distance <= GameConfig.Entity.HearRange and snap.isSprinting
			end
			-- "sonar" : visible/audible restent false (l'écholocation n'en dépend
			-- pas) ; la position est remplie inconditionnellement ci-dessous.

			local position: Vector3? = nil
			if fillPolicy == "sonar" then
				position = survPos -- traverse les murs (sonar)
			elseif visible or audible then
				position = survPos -- gating EntityAI
			end

			table.insert(out, {
				userId = userId,
				distance = distance,
				visible = visible,
				audible = audible,
				lifeState = snap.lifeState,
				position = position,
			})
		end
	end

	return out
end

-- ───────────────────────────────────────────────────────────────────────
-- AssignRole : émission ciblée (FireClient, jamais FireAllClients)
-- ───────────────────────────────────────────────────────────────────────

-- Idempotent : le rôle est stable sur la manche. Réémis sur (re)spawn pendant
-- Playing (voir onCharacterAdded) pour couvrir un client chargé tardivement —
-- la garantie « le client a son rôle » est structurelle (le client gate ses
-- contrôles sur la réception), pas temporelle. ⚠️ À VALIDER DANS STUDIO.
local function sendRole(player: Player)
	local role = roleManager:getRole(player.UserId)
	if role == nil then
		return -- pas (encore) assigné : rien à envoyer
	end
	Remotes.AssignRole:FireClient(player, role)
end

-- ───────────────────────────────────────────────────────────────────────
-- Pilotage HUMAIN (capacités + écholocation + vitesse)
-- ───────────────────────────────────────────────────────────────────────

local function tickHuman(dt: number)
	local controller = echoController
	local uid = echoUserId
	if not controller or not uid then
		return
	end

	-- Capture défensive de la position de l'Écho AVANT tout (sert de spawn IA si
	-- l'Écho quitte : on ne pourra plus la lire à ce moment-là).
	local echoPos = getRootPosition(uid)
	if echoPos then
		lastEchoPosition = echoPos
	end

	-- Observations sonar (position toujours remplie) → pulse d'écholocation.
	-- Sans position d'observateur (perso en chargement), on saute le calcul.
	local pings: { Types.EcholocationPing }? = nil
	if echoPos then
		local obs = buildObservations(echoPos, "sonar", {})
		pings = controller:update(dt, obs)
	else
		controller:update(dt, {}) -- avance quand même cooldowns/effets
	end

	local echoPlayer = Players:GetPlayerByUserId(uid)
	if echoPlayer then
		-- Écholocation : SEULEMENT sur tick de pulse (pings non-nil), au SEUL Écho.
		if pings ~= nil then
			Remotes.Echolocation:FireClient(echoPlayer, pings)
			-- EchoState bundlé à la cadence du pulse (le client décompte localement
			-- ses jauges entre deux pushes).
			Remotes.EchoState:FireClient(echoPlayer, controller:getState())
		end
	end

	-- Vitesse effective (Frenzy reflété automatiquement) appliquée au Humanoid.
	-- L'Écho n'étant PAS inscrit dans PlayerState (exclusion 6c, onPlayingStarted),
	-- PlayerService.applyMovement ne touche jamais son WalkSpeed : EchoService en est
	-- le seul pilote, plus de double-pilotage.
	local humanoid = getHumanoid(uid)
	if humanoid then
		humanoid.WalkSpeed = controller:getMoveSpeed()
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Pilotage IA (EntityAI = navigation + frappe ; EchoController dormant en MVP)
-- ───────────────────────────────────────────────────────────────────────

local function tickAI(dt: number)
	local ai = entityAI
	if not ai then
		return
	end

	local entityRoot = getEntityRoot()
	if not entityRoot then
		return -- ⚠️ pas de corps d'entité (asset Studio) : l'IA n'agit pas ce tick.
	end

	-- Observations gated (visible/audible) pour la nav de l'IA. update renvoie le
	-- coup frappé ET la capacité demandée à l'entrée d'une phase (cf. EntityAI).
	local obs = buildObservations(entityRoot.Position, "onContact", { entityRoot.Parent :: Instance })
	local hit, abilityRequest = ai:update(dt, obs)

	-- ⚠️ À VALIDER DANS STUDIO : déplacement réel du corps (MoveTo/pathfinding)
	-- d'après ai:getState() (lastKnownPosition + phase → PatrolSpeed/ChaseSpeed),
	-- avec multiplicateur de Frénésie lu sur echoController:getState().frenzy
	-- (activeRemaining > 0). Branchement minimal : on laisse le mouvement à Studio.

	-- Hook capacités IA : EntityAI a décidé (Frenzy en Chase, Howl en Search) ;
	-- requestAbility est le GARDIEN du cooldown (ignore si indispo) → EntityAI
	-- reste pur, aucun couplage. Ordre requestAbility→update comme le flux humain.
	if echoController then
		if abilityRequest ~= nil then
			echoController:requestAbility(abilityRequest)
		end
		echoController:update(dt, {})
	end

	-- Le coup qui part est appliqué via PlayerService (autorité PlayerState).
	if hit ~= nil then
		PlayerService.applyAttack(hit)
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Démarrage / fin de manche
-- ───────────────────────────────────────────────────────────────────────

-- Entrée en Playing : fige le mode (décision #7), crée les instances fraîches,
-- assigne et notifie les rôles.
local function onPlayingStarted()
	local playerIds: { number } = {}
	for _, player in Players:GetPlayers() do
		table.insert(playerIds, player.UserId)
	end

	roleManager:assignRoles(playerIds)
	echoController = EchoController.new()
	lastEchoPosition = nil
	missingEntityWarned = false
	lastMeleeAt = -1e9 -- mêlée immédiatement disponible pour le nouvel Écho

	if roleManager:isHumanEcho() then
		mode = "Human"
		echoUserId = roleManager:getEchoUserId()
		entityAI = nil
	else
		mode = "AI"
		echoUserId = nil
		entityAI = EntityAI.new()
	end

	-- Notifie chaque joueur de son rôle (FireClient ciblé).
	for _, player in Players:GetPlayers() do
		sendRole(player)
	end
end

-- Sortie de Playing : on cesse de piloter ; instances par-manche libérées.
local function onPlayingEnded()
	echoController = nil
	entityAI = nil
	mode = nil
	echoUserId = nil
	lastEchoPosition = nil
end

-- Bascule humain → IA en cours de manche (l'Écho humain a quitté). Décision
-- actée : pas d'annulation, pas de victoire survivant par défaut.
local function switchToAI()
	mode = "AI"
	echoUserId = nil
	entityAI = EntityAI.new()
	-- ⚠️ À VALIDER DANS STUDIO : on FERA apparaître le corps de l'entité à
	-- lastEchoPosition (capturée AVANT le départ, cf. tickHuman) avec repli sur un
	-- spawn si nil. Le spawn/déplacement concret du modèle est l'étape asset entité.
	local _spawnPos = lastEchoPosition
	print("[EchoService] Écho humain parti → bascule IA pour le reste de la manche.")
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
-- Tick serveur
-- ───────────────────────────────────────────────────────────────────────

local function tick(dt: number)
	resolvePhase()

	-- Hors Playing : rien à piloter.
	if RoundService.getRoundManager():getPhase() ~= Types.RoundPhase.Playing then
		return
	end

	-- Détection passive de la bascule (l'Écho humain a quitté → RoleManager a
	-- remis isHumanEcho() à false ; on réagit ici, RoleManager reste passif).
	if mode == "Human" and not roleManager:isHumanEcho() then
		switchToAI()
	end

	if mode == "Human" then
		tickHuman(dt)
	elseif mode == "AI" then
		tickAI(dt)
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Remotes (client → serveur) — AUTORITÉ SERVEUR STRICTE
-- ───────────────────────────────────────────────────────────────────────

-- Décorateur anti-flood (identique à PlayerService) : garde token bucket posée
-- au site de branchement, corps du handler intact. Rejet → drop silencieux
-- (+ warn une fois par rafale en Studio). Les Remotes Écho portent 0 ou 1 charge.
local function guarded(name: string, capacity: number, refillPerSec: number, handler: (Player, any) -> ())
	return function(player: Player, payload: any)
		local uid = player.UserId
		local allowed, firstRejection = rateLimiter:allow(uid, name, capacity, refillPerSec, os.clock())
		if not allowed then
			if IS_STUDIO and firstRejection then
				warn(string.format("[EchoService] Rate limit : %s rejeté (rafale) pour le joueur %d.", name, uid))
			end
			return
		end
		handler(player, payload)
	end
end

-- Identité = TOUJOURS `player` (OnServerEvent). Revalidation : seul l'Écho humain
-- COURANT est accepté. Un survivant (ou quiconque ≠ Écho) est rejeté ici.
local function onActivateAbility(player: Player, abilityId: unknown)
	if type(abilityId) ~= "string" then
		return
	end
	if mode ~= "Human" or player.UserId ~= echoUserId then
		return -- pas l'Écho courant : rejeté
	end
	local controller = echoController
	if not controller then
		return
	end
	controller:requestAbility(abilityId :: Types.AbilityId) -- ignore en plus id invalide / cooldown
end

-- Cible de mêlée résolue 100 % SERVEUR (le client n'en fournit aucune) : survivant
-- inscrit Alive/Downed le plus proche DANS AttackRange de `echoPos`. Priorité
-- Alive > Downed puis distance (cohérent avec EntityAI.selectTarget). nil sinon.
local function resolveMeleeTarget(echoPos: Vector3): number?
	local playerState = PlayerService.getPlayerState()
	local range = GameConfig.Entity.AttackRange
	local bestAlive: number?, bestAliveDist = nil, range
	local bestDowned: number?, bestDownedDist = nil, range

	for userId, snap in playerState:getAllStates() do
		if snap.lifeState == Types.LifeState.Alive or snap.lifeState == Types.LifeState.Downed then
			local pos = getRootPosition(userId)
			if pos then
				local d = (pos - echoPos).Magnitude
				if d <= range then
					if snap.lifeState == Types.LifeState.Alive and d < bestAliveDist then
						bestAlive, bestAliveDist = userId, d
					elseif snap.lifeState == Types.LifeState.Downed and d < bestDownedDist then
						bestDowned, bestDownedDist = userId, d
					end
				end
			end
		end
	end
	return bestAlive or bestDowned
end

-- Mêlée de l'Écho humain. AUTORITÉ SERVEUR : identité (player) + Écho courant +
-- cooldown + portée + lifeState tous revalidés. Aucune cible reçue du client.
local function onMeleeAttack(player: Player)
	if mode ~= "Human" or player.UserId ~= echoUserId then
		return -- pas l'Écho courant
	end
	if os.clock() - lastMeleeAt < GameConfig.Entity.AttackCooldown then
		return -- cooldown (anti-spam du Remote)
	end
	local echoPos = getRootPosition(player.UserId)
	if not echoPos then
		return -- perso pas chargé
	end
	local targetId = resolveMeleeTarget(echoPos)
	if not targetId then
		return -- aucune cible valide en portée : swing dans le vide, pas de cooldown
	end
	lastMeleeAt = os.clock() -- consommé seulement sur un coup RÉUSSI
	PlayerService.applyAttack(targetId) -- Alive→Downed / Downed→Dead (+ crédit kill-XP)
	Remotes.SoundEvent:FireClient(player, { soundId = SoundConfig.ECHO_ATTACK })
end

-- ───────────────────────────────────────────────────────────────────────
-- Joueurs : présence suivie par RoleManager + (re)notification de rôle
-- ───────────────────────────────────────────────────────────────────────

local function onCharacterAdded(player: Player)
	-- Réémet le rôle si une manche est déjà en cours (client chargé tardivement).
	if RoundService.getRoundManager():getPhase() == Types.RoundPhase.Playing then
		sendRole(player)
	end
end

local function registerPlayer(player: Player)
	roleManager:onPlayerJoined(player.UserId)
	player.CharacterAdded:Connect(function()
		onCharacterAdded(player)
	end)
end

local function removePlayer(player: Player)
	roleManager:onPlayerLeft(player.UserId)
	rateLimiter:removePlayer(player.UserId) -- libère les seaux anti-flood du joueur
end

-- ───────────────────────────────────────────────────────────────────────
-- Interface publique
-- ───────────────────────────────────────────────────────────────────────

-- Exposé pour PlayerService (6c) : exclusion de l'Écho via getEchoUserId().
function EchoService.getRoleManager(): RoleManager.RoleManager
	return roleManager
end

-- Point d'entrée unique. Appelé par init.server.luau APRÈS RoundService.init()
-- (on lit sa phase) et AVANT PlayerService.init() (qui lira getRoleManager()).
function EchoService.init()
	if initialized then
		return
	end
	initialized = true

	for _, player in Players:GetPlayers() do
		registerPlayer(player)
	end
	Players.PlayerAdded:Connect(registerPlayer)
	Players.PlayerRemoving:Connect(removePlayer)

	-- Limites premier jet (généreuses, ⚠️ PARI) : garde anti-flood en plus des
	-- cooldowns de gameplay (Howl/Frénésie dans EchoController, mêlée 2 s ici).
	Remotes.ActivateAbility.OnServerEvent:Connect(guarded("ActivateAbility", 4, 2, onActivateAbility))
	Remotes.MeleeAttack.OnServerEvent:Connect(guarded("MeleeAttack", 5, 3, onMeleeAttack))

	RunService.Heartbeat:Connect(tick)
end

return EchoService
