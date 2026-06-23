--!strict
-- FuseService — Pilote FuseSystem (Logic) : place les fusibles dans la map, gère
-- les interactions (ramasser/déposer via ProximityPrompt), déverrouille la sortie
-- au 5/5, et — MAILLON CRITIQUE — déclenche l'évasion (markEscaped) quand un
-- survivant Alive atteint la sortie déverrouillée.
--
-- ─── FuseSystem reste PUR & PASSIF ──────────────────────────────────────
-- FuseSystem ne connaît ni la 3D, ni PlayerState, ni les causes. FuseService :
--   - lui FOURNIT l'identité des fusibles (registerFuse(i), i = index de spot) ;
--   - SYNCHRONISE la 3D sur l'état logique (Hidden→spot, Carried→porteur,
--     Deposited→générateur) à chaque tick ;
--   - appelle releaseCarriedBy au bon moment (départ / Downed / Dead détectés ici).
--
-- ─── FuseService PRODUIT l'évasion, PlayerService la CONSOMME ────────────
-- FuseService appelle PlayerService.markEscaped(userId) ; il NE résout PAS la
-- manche lui-même. C'est resolveRoundResolution (PlayerService) qui lit
-- areAllSurvivorsResolved/hasAnyEscaped. Aucun appel FuseService → RoundService.
--
-- ⚠️ NON EXÉCUTABLE HORS STUDIO : glue lourdement API Roblox (modèles,
-- ProximityPrompt, Touched, CanCollide). La logique pure (FuseSystem) est déjà
-- shim-testée (scénarios 10-17). Ici : luau-analyze + validation Studio.
--
-- ⚠️ GARDES DÉFENSIFS SYSTÉMATIQUES : la map est amenée à évoluer. CHAQUE accès
-- Workspace (FuseSpot{i}, Generator, ExitBarrier, ExitZone, template) est gardé :
-- objet manquant → warn clair (une fois) + retour propre, JAMAIS de crash.
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- require uniforme, ISOLÉ. Couplage runtime vers PlayerService (état porteurs +
-- markEscaped) et RoundService (phase) — à sens unique (personne ne require
-- FuseService) → pas de cycle.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FuseSystem = require(ServerStorage.Logic.FuseSystem)
local Types = require(ReplicatedStorage.Shared.Types)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RoundService = require(script.Parent.RoundService)
local PlayerService = require(script.Parent.PlayerService)

local FuseService = {}

-- Debounce d'évasion (Touched est bruyant) : userId -> os.clock du dernier
-- traitement. ~0.5 s, EN PLUS du garde Alive.
local ESCAPE_DEBOUNCE = 0.5

-- ───────────────────────────────────────────────────────────────────────
-- État de module
-- ───────────────────────────────────────────────────────────────────────

local fuseSystem: FuseSystem.FuseSystem = FuseSystem.new()

-- Ponts id ↔ 3D. fuseId = index de spot (1..Total).
local fuseSpots: { [number]: BasePart } = {}
local fuseParts: { [number]: BasePart } = {}

local exitUnlocked = false
local recentlyEscaped: { [number]: number } = {} -- userId -> os.clock
local lastPhase: Types.RoundPhase = RoundService.getRoundManager():getPhase()
-- Connexions monde INDÉPENDANTES : un objet absent ne doit pas bloquer l'autre
-- (sinon un ExitZone manquant empêcherait le branchement du dépôt au générateur).
local generatorConnected = false
local exitConnected = false
local initialized = false

-- Warn une seule fois par clé (anti-spam quand un objet manque tick après tick).
local warned: { [string]: boolean } = {}
local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	warn(message)
end

-- ───────────────────────────────────────────────────────────────────────
-- Accès map défensifs
-- ───────────────────────────────────────────────────────────────────────

local function getMapChild(name: string): Instance?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		warnOnce("Map", "[FuseService] Workspace.Map introuvable. ⚠️ map à valider.")
		return nil
	end
	local child = map:FindFirstChild(name)
	if not child then
		warnOnce("Map." .. name, "[FuseService] Workspace.Map." .. name .. " introuvable. ⚠️ map à valider.")
		return nil
	end
	return child
end

local function getMapBasePart(name: string): BasePart?
	local child = getMapChild(name)
	if child and child:IsA("BasePart") then
		return child
	end
	if child then
		warnOnce("type." .. name, "[FuseService] Workspace.Map." .. name .. " n'est pas une BasePart. ⚠️")
	end
	return nil
end

-- Spot d'un fusible : Workspace.Map.FuseSpots.FuseSpot{index} — dossier
-- intermédiaire FuseSpots. Chaque niveau gardé défensivement (Map, FuseSpots,
-- FuseSpot{index}, type BasePart) → warn clair + nil, jamais de crash.
local function getFuseSpot(index: number): BasePart?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		warnOnce("Map", "[FuseService] Workspace.Map introuvable. ⚠️ map à valider.")
		return nil
	end
	local folder = map:FindFirstChild("FuseSpots")
	if not folder then
		warnOnce("FuseSpots", "[FuseService] Workspace.Map.FuseSpots introuvable. ⚠️ map à valider.")
		return nil
	end
	local name = "FuseSpot" .. index
	local spot = folder:FindFirstChild(name)
	if not spot then
		warnOnce("FuseSpots." .. name, "[FuseService] Workspace.Map.FuseSpots." .. name .. " introuvable. ⚠️ map à valider.")
		return nil
	end
	if not spot:IsA("BasePart") then
		warnOnce("type.FuseSpots." .. name, "[FuseService] Workspace.Map.FuseSpots." .. name .. " n'est pas une BasePart. ⚠️")
		return nil
	end
	return spot
end

-- Dossier conteneur des modèles de fusibles (créé si absent).
local function fusesFolder(): Folder
	local existing = Workspace:FindFirstChild("Fuses")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Fuses"
	folder.Parent = Workspace
	return folder
end

-- HumanoidRootPart d'un joueur, ou nil (perso pas chargé).
local function getHRP(userId: number): BasePart?
	local player = Players:GetPlayerByUserId(userId)
	if not player or not player.Character then
		return nil
	end
	local root = player.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Vrai si userId est un survivant Alive INSCRIT (exclut l'Écho non inscrit, et
-- les Downed/Dead/Escaped). Le garde lifeState vit ICI : FuseSystem est
-- state-ignorant (pickup ne vérifie que Hidden + un seul porté).
local function isAliveSurvivor(userId: number): boolean
	local snap = PlayerService.getPlayerState():getState(userId)
	return snap ~= nil and snap.lifeState == Types.LifeState.Alive
end

-- ───────────────────────────────────────────────────────────────────────
-- Interactions (handlers définis AVANT makeFusePart / setup pour les closures)
-- ───────────────────────────────────────────────────────────────────────

local function onFusePromptTriggered(fuseId: number, player: Player)
	if not isAliveSurvivor(player.UserId) then
		return -- Écho / Downed / Dead : rejeté (garde FuseService, pas FuseSystem)
	end
	-- pickup applique ses propres gardes (Hidden, un seul porté) et renvoie un bool.
	fuseSystem:pickup(fuseId, player.UserId)
	-- Le visuel suit via reconcileVisuals (Carried → porteur).
end

-- Vérifie le 5/5 et déverrouille la sortie une seule fois.
local function checkExitUnlock()
	local progress = fuseSystem:getProgress()
	if progress.collected < progress.required or exitUnlocked then
		return
	end
	local barrier = getMapBasePart("ExitBarrier")
	if barrier then
		barrier.CanCollide = false
		barrier.Transparency = 0.7 -- « ouverte » sans la détruire (réversible au reset)
	end
	exitUnlocked = true
	print("[FuseService] 5/5 fusibles déposés — sortie déverrouillée.")
end

local function onGeneratorTriggered(player: Player)
	if not isAliveSurvivor(player.UserId) then
		return
	end
	-- Trouver le fusible porté par ce joueur.
	local carriedId: number? = nil
	for fuseId, snap in fuseSystem:getAllStates() do
		if snap.state == Types.FuseLifeState.Carried and snap.carriedBy == player.UserId then
			carriedId = fuseId
			break
		end
	end
	if carriedId == nil then
		return -- ne porte rien : rien à déposer
	end
	if fuseSystem:deposit(carriedId, player.UserId) then
		local progress = fuseSystem:getProgress()
		print(string.format("[FuseService] Fusible %d déposé (%d/%d).", carriedId, progress.collected, progress.required))
		checkExitUnlock()
	end
end

-- MAILLON CRITIQUE : un survivant Alive touche la sortie DÉVERROUILLÉE → évasion.
local function onExitTouched(hit: BasePart)
	if not exitUnlocked then
		return -- zone inerte tant que 5/5 non atteint
	end
	local character = hit.Parent
	if not character then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return -- pas un personnage joueur (débris, etc.)
	end
	local userId = player.UserId

	-- Debounce par userId (Touched est bruyant), EN PLUS du garde Alive.
	local now = os.clock()
	local last = recentlyEscaped[userId]
	if last ~= nil and (now - last) < ESCAPE_DEBOUNCE then
		return
	end
	recentlyEscaped[userId] = now

	if not isAliveSurvivor(userId) then
		return -- déjà Escaped (non-Alive) → no-op ; ou non-survivant
	end
	PlayerService.markEscaped(userId) -- alimente resolveRoundResolution (6c)
end

-- ───────────────────────────────────────────────────────────────────────
-- Création / placement des modèles
-- ───────────────────────────────────────────────────────────────────────

-- Crée le modèle d'un fusible : clone ServerStorage.Assets.FuseTemplate si
-- présent, sinon une Part néon de repli (le MVP se contente d'une Part visible).
-- Ajoute un ProximityPrompt programmatique (pas de dépendance d'asset au prompt).
local function makeFusePart(fuseId: number): BasePart
	local assets = ServerStorage:FindFirstChild("Assets")
	local template = assets and assets:FindFirstChild("FuseTemplate")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone()
	else
		warnOnce("FuseTemplate", "[FuseService] ServerStorage.Assets.FuseTemplate absent : Part de repli utilisée. ⚠️ asset.")
		local p = Instance.new("Part")
		p.Size = Vector3.new(1, 1, 2)
		p.Color = Color3.fromRGB(255, 200, 40)
		p.Material = Enum.Material.Neon
		part = p
	end
	part.Name = "Fuse" .. fuseId
	part.Anchored = true
	part.CanCollide = false

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Ramasser le fusible"
	prompt.ObjectText = "Fusible"
	prompt.HoldDuration = GameConfig.Interaction.FuseGrabTime
	prompt.MaxActivationDistance = GameConfig.Interaction.Distance
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		onFusePromptTriggered(fuseId, player)
	end)

	return part
end

-- Synchronise la 3D sur l'état logique (Hidden→spot, Carried→porteur,
-- Deposited→générateur). Tourne chaque tick : porte le suivi du fusible porté.
local function reconcileVisuals()
	local generator = getMapBasePart("Generator")
	for fuseId, part in fuseParts do
		if not part.Parent then
			continue
		end
		local snap = fuseSystem:getState(fuseId)
		if not snap then
			continue
		end
		local prompt = part:FindFirstChildOfClass("ProximityPrompt")

		if snap.state == Types.FuseLifeState.Hidden then
			local spot = fuseSpots[fuseId]
			if spot then
				part.CFrame = spot.CFrame + Vector3.new(0, 3, 0)
			end
			if prompt then
				prompt.Enabled = true
			end
		elseif snap.state == Types.FuseLifeState.Carried then
			if prompt then
				prompt.Enabled = false
			end
			local carrierId = snap.carriedBy
			if carrierId then
				local hrp = getHRP(carrierId)
				if hrp then
					part.CFrame = hrp.CFrame * CFrame.new(0, 2, 0) -- suit le porteur (anchored teleport)
				end
			end
		elseif snap.state == Types.FuseLifeState.Deposited then
			if prompt then
				prompt.Enabled = false
			end
			if generator then
				part.CFrame = generator.CFrame + Vector3.new(0, 4, 0)
			end
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Libération des fusibles portés (départ / Downed / Dead)
-- ───────────────────────────────────────────────────────────────────────

-- Comparaison passive : un porteur qui n'est plus Alive (Downed/Dead) lâche son
-- fusible via le point d'entrée UNIQUE releaseCarriedBy. Le départ est couvert
-- en plus par PlayerRemoving (idempotent). Le visuel revient au spot (Hidden).
local function resolveReleases()
	local playerState = PlayerService.getPlayerState()
	for _, snap in fuseSystem:getAllStates() do
		if snap.state == Types.FuseLifeState.Carried and snap.carriedBy then
			local carrier = playerState:getState(snap.carriedBy)
			if not carrier or carrier.lifeState ~= Types.LifeState.Alive then
				fuseSystem:releaseCarriedBy(snap.carriedBy)
			end
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Connexions monde (générateur + sortie) — une seule fois, dès que dispo
-- ───────────────────────────────────────────────────────────────────────

-- Branche le générateur (dépôt) et la sortie (évasion) SÉPARÉMENT : chacun se
-- connecte dès que SON objet est disponible, indépendamment de l'autre. Idempotent
-- via les deux flags ; réessayé à chaque onPlayingStarted tant qu'un objet manque.
local function setupWorldConnections()
	-- Générateur → prompt de dépôt (NE dépend PLUS de ExitZone).
	if not generatorConnected then
		local generator = getMapBasePart("Generator")
		if generator then
			local generatorPrompt = generator:FindFirstChildOfClass("ProximityPrompt")
			if not generatorPrompt then
				local p = Instance.new("ProximityPrompt")
				p.ActionText = "Déposer le fusible"
				p.ObjectText = "Générateur"
				p.HoldDuration = GameConfig.Interaction.FuseGrabTime
				p.MaxActivationDistance = GameConfig.Interaction.Distance
				p.RequiresLineOfSight = false
				p.Parent = generator
				generatorPrompt = p
			end
			generatorPrompt.Triggered:Connect(onGeneratorTriggered)
			generatorConnected = true
		end
	end

	-- Sortie → détection d'évasion (NE bloque PLUS le générateur si absente).
	if not exitConnected then
		local exitZone = getMapBasePart("ExitZone")
		if exitZone then
			exitZone.Touched:Connect(onExitTouched)
			exitConnected = true
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Démarrage de manche
-- ───────────────────────────────────────────────────────────────────────

-- Verrouille (ou re-verrouille) la sortie. Défensif sur ExitBarrier.
local function lockExit()
	local barrier = getMapBasePart("ExitBarrier")
	if barrier then
		barrier.CanCollide = true
		barrier.Transparency = 0
	end
	exitUnlocked = false
end

local function onPlayingStarted()
	setupWorldConnections() -- réessai si la map est arrivée après l'init

	-- Résolution des spots + enregistrement + création des modèles + garde-fou compte.
	local folder = fusesFolder()
	local found = 0
	for i = 1, GameConfig.Fuses.Total do
		local spot = getFuseSpot(i)
		if spot then
			fuseSpots[i] = spot
			fuseSystem:registerFuse(i) -- idempotent
			if not fuseParts[i] then
				fuseParts[i] = makeFusePart(i)
			end
			fuseParts[i].Parent = folder
			found += 1
		end
	end
	if found < GameConfig.Fuses.Total then
		warnOnce(
			"count",
			string.format(
				"[FuseService] %d/%d FuseSpot trouvés : le 5/5 sera INATTEIGNABLE. ⚠️ map.",
				found,
				GameConfig.Fuses.Total
			)
		)
	end

	fuseSystem:resetRound() -- tout → Hidden
	lockExit()
	table.clear(recentlyEscaped)
	reconcileVisuals() -- repositionne immédiatement les modèles sur leurs spots
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
-- Tick serveur
-- ───────────────────────────────────────────────────────────────────────

local function tick(_dt: number)
	resolvePhase()
	if RoundService.getRoundManager():getPhase() ~= Types.RoundPhase.Playing then
		return
	end
	resolveReleases()
	reconcileVisuals()
end

-- ───────────────────────────────────────────────────────────────────────
-- Joueurs
-- ───────────────────────────────────────────────────────────────────────

local function onPlayerRemoving(player: Player)
	fuseSystem:releaseCarriedBy(player.UserId) -- lâche tout fusible porté (départ)
	recentlyEscaped[player.UserId] = nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Interface publique
-- ───────────────────────────────────────────────────────────────────────

-- Point d'entrée unique. Appelé par init.server.luau APRÈS PlayerService.init()
-- (on lit son état et on appelle markEscaped).
function FuseService.init()
	if initialized then
		return
	end
	initialized = true

	setupWorldConnections()
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	RunService.Heartbeat:Connect(tick)
end

return FuseService
