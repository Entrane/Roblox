--!strict
-- EchoController (client) — LocalScript AUTONOME pour le rôle Écho.
--
-- POURQUOI un LocalScript et pas un module piloté par init.client : le suffixe
-- « .client » en fait un LocalScript côté Rojo (non requérable). Il s'AUTO-GATE
-- donc sur AssignRole : il (dé)s'active selon que le rôle reçu est Echo ou non.
-- init.client gère, lui, la visibilité des boutons (HudController.setRole) et les
-- controllers survivant ; ici on ne gère QUE la logique Écho.
--
-- Responsabilités :
--   - inputs Howl/Frenzy → ActivateAbility (touch boutons HUD + clavier) ;
--   - écoute Echolocation → Highlight par userId (visible À TRAVERS LES MURS) ;
--   - écoute EchoState → cooldowns sur les boutons (HudController.setAbilityState).
--
-- ⚠️ Anti-triche partiel : Roblox réplique déjà tous les personnages à tous les
-- clients ; l'écholocation ne fait que choisir QUI surligner, elle ne cache pas
-- les positions non pingées (cela demanderait une réplication custom, hors MVP).

local Players = game:GetService("Players")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local HudController = require(script.Parent.HudController)

local localPlayer = Players.LocalPlayer
local HOWL_ACTION = "SL_Howl"
local FRENZY_ACTION = "SL_Frenzy"
local MELEE_ACTION = "SL_Melee"
local MELEE_SCAN_INTERVAL = 0.2 -- s
local meleeScanAccum = 0
local meleeButtonShown = false

local active = false
-- { any } : RBXScriptConnection inconnu hors Studio (cf. InputController).
local connections: { any } = {}
local markers: { [number]: Highlight } = {} -- userId -> Highlight
local markersFolder: Folder? = nil

local function activateAbility(abilityId: Types.AbilityId)
	Remotes.ActivateAbility:FireServer(abilityId)
end

local function onHowlKey(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		activateAbility(Types.AbilityId.Howl)
	end
	return Enum.ContextActionResult.Pass
end

local function onFrenzyKey(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		activateAbility(Types.AbilityId.Frenzy)
	end
	return Enum.ContextActionResult.Pass
end

-- Demande de mêlée : aucune cible envoyée, le SERVEUR la résout (et revalide
-- portée/cooldown/lifeState). Le client ne fait que signaler l'intention.
local function requestMelee()
	Remotes.MeleeAttack:FireServer()
end

local function onMeleeKey(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		requestMelee()
	end
	return Enum.ContextActionResult.Pass
end

local function hrpOf(character: Instance?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Scan LOCAL : un survivant à portée de mêlée ? (pour la visibilité du bouton
-- seulement — la cible réelle reste résolue serveur). True si un autre personnage
-- vivant (Health > 0) est à <= AttackRange de l'Écho.
local function aSurvivorInRange(): boolean
	local myHRP = hrpOf(localPlayer.Character)
	if not myHRP then
		return false
	end
	local range = GameConfig.Entity.AttackRange
	for _, other in Players:GetPlayers() do
		if other ~= localPlayer and other.Character then
			local hum = other.Character:FindFirstChildOfClass("Humanoid")
			local hrp = hrpOf(other.Character)
			if hum and hrp and hum.Health > 0 and (hrp.Position - myHRP.Position).Magnitude <= range then
				return true
			end
		end
	end
	return false
end

local function onMeleeScan(dt: number)
	meleeScanAccum += dt
	if meleeScanAccum < MELEE_SCAN_INTERVAL then
		return
	end
	meleeScanAccum = 0
	local inRange = aSurvivorInRange()
	if inRange ~= meleeButtonShown then
		meleeButtonShown = inRange
		HudController.setMeleeVisible(inRange)
	end
end

-- Dossier conteneur des Highlights (dans Workspace, local). Les Highlights y
-- VIVENT (pas parentés aux persos) → ils survivent à un respawn ; on ne fait que
-- pointer leur Adornee sur le personnage courant.
local function getMarkersFolder(): Folder
	if markersFolder and markersFolder.Parent then
		return markersFolder
	end
	local f = Instance.new("Folder")
	f.Name = "EchoMarkers"
	f.Parent = Workspace
	markersFolder = f
	return f
end

local function clearMarkers()
	for userId, h in markers do
		h:Destroy()
		markers[userId] = nil
	end
	if markersFolder then
		markersFolder:Destroy()
		markersFolder = nil
	end
end

-- Reçu au pulse (~2 Hz) : (re)surligne les userId présents, retire les absents.
local function onEcholocation(pings: { Types.EcholocationPing })
	if type(pings) ~= "table" then
		return
	end
	local seen: { [number]: boolean } = {}
	for _, ping in pings do
		local userId = ping.userId
		if type(userId) == "number" then
			seen[userId] = true
			local player = Players:GetPlayerByUserId(userId)
			local character = player and player.Character
			local h = markers[userId]
			if not h then
				h = Instance.new("Highlight")
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- à travers les murs
				h.FillColor = Color3.fromRGB(255, 60, 60)
				h.FillTransparency = 0.55
				h.OutlineColor = Color3.fromRGB(255, 140, 140)
				h.Parent = getMarkersFolder()
				markers[userId] = h
			end
			h.Adornee = character -- nil si perso pas chargé → invisible ce pulse
		end
	end
	-- Nettoyage des survivants absents du pulse courant.
	for userId, h in markers do
		if not seen[userId] then
			h:Destroy()
			markers[userId] = nil
		end
	end
end

local function onEchoState(state: Types.EchoState)
	if type(state) ~= "table" then
		return
	end
	if state.howl then
		HudController.setAbilityState(Types.AbilityId.Howl, state.howl.cooldownRemaining, state.howl.activeRemaining)
	end
	if state.frenzy then
		HudController.setAbilityState(Types.AbilityId.Frenzy, state.frenzy.cooldownRemaining, state.frenzy.activeRemaining)
	end
end

local function activate()
	if active then
		return
	end
	active = true

	-- Touch : boutons HUD (rendus visibles par init.client via setRole(Echo)).
	local howlBtn = HudController.getButton("Howl")
	if howlBtn then
		table.insert(connections, (howlBtn.Activated:Connect(function()
			activateAbility(Types.AbilityId.Howl)
		end)))
	end
	local frenzyBtn = HudController.getButton("Frenzy")
	if frenzyBtn then
		table.insert(connections, (frenzyBtn.Activated:Connect(function()
			activateAbility(Types.AbilityId.Frenzy)
		end)))
	end
	-- Mêlée : bouton contextuel (visibilité pilotée par le scan) + touche E.
	local meleeBtn = HudController.getButton("Melee")
	if meleeBtn then
		table.insert(connections, (meleeBtn.Activated:Connect(requestMelee)))
	end

	-- Clavier (test PC). Mêlée = E (l'Écho n'a pas de torche → pas de conflit).
	ContextActionService:BindAction(HOWL_ACTION, onHowlKey, false, Enum.KeyCode.Q)
	ContextActionService:BindAction(FRENZY_ACTION, onFrenzyKey, false, Enum.KeyCode.R)
	ContextActionService:BindAction(MELEE_ACTION, onMeleeKey, false, Enum.KeyCode.E)

	-- Scan de proximité (visibilité du bouton mêlée).
	meleeScanAccum = 0
	meleeButtonShown = false
	table.insert(connections, (RunService.Heartbeat:Connect(onMeleeScan)))

	-- Flux serveur→client réservés à l'Écho.
	table.insert(connections, (Remotes.Echolocation.OnClientEvent:Connect(onEcholocation)))
	table.insert(connections, (Remotes.EchoState.OnClientEvent:Connect(onEchoState)))
end

local function deactivate()
	if not active then
		return
	end
	active = false

	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)

	ContextActionService:UnbindAction(HOWL_ACTION)
	ContextActionService:UnbindAction(FRENZY_ACTION)
	ContextActionService:UnbindAction(MELEE_ACTION)
	HudController.setMeleeVisible(false)
	meleeButtonShown = false

	clearMarkers()
end

-- Auto-gate sur le rôle. HudController.init() est garanti par init.client (même
-- instance de module en cache) avant l'arrivée d'AssignRole (réseau).
Remotes.AssignRole.OnClientEvent:Connect(function(role: unknown)
	if role == Types.Role.Echo then
		activate()
	else
		deactivate()
	end
end)
