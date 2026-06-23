--!strict
-- SpectatorController — Mode spectateur pour les joueurs éliminés (Dead/Escaped).
-- ModuleScript initialisé par init.client (comme ProgressionController, NON
-- role-gated). Quand le joueur local est Dead/Escaped (lifeState reçu via
-- PlayerHud), il observe les survivants restants ; il en sort au respawn
-- (lifeState Alive) ou au retour Lobby.
--
-- ─── 100 % CLIENT, AUCUNE DONNÉE SERVEUR SUPPLÉMENTAIRE ──────────────────
-- Les personnages sont déjà répliqués par Roblox : un éliminé (hors manche) peut
-- légitimement les observer. On ne fait que déplacer CameraSubject. L'info
-- secrète de l'Écho (écholocation) n'est JAMAIS concernée — autre canal, ciblé.
--
-- ⚠️ À VALIDER DANS STUDIO : caméra (CameraSubject/CameraType), respawn, Tab.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)

local SpectatorController = {}

local localPlayer = Players.LocalPlayer
local NEXT_ACTION = "SL_SpectateNext"

local active = false
local initialized = false
local targets: { Player } = {} -- survivants observables (Alive/Downed), recalculés à chaque action
local index = 1
local gui: ScreenGui? = nil
local nameLabel: TextLabel? = nil

-- ───────────────────────────────────────────────────────────────────────
-- Helpers monde (défensifs)
-- ───────────────────────────────────────────────────────────────────────

local function ownHumanoid(): Humanoid?
	local char = localPlayer.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

-- Humanoid d'un AUTRE joueur encore en jeu (Health > 0 → Alive OU Downed), sinon
-- nil. Un mort (Health 0) ou sans perso est exclu des cibles.
local function liveHumanoidOf(player: Player): Humanoid?
	local char = player.Character
	if not char then
		return nil
	end
	local h = char:FindFirstChildOfClass("Humanoid")
	if h and h.Health > 0 then
		return h
	end
	return nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Cible / caméra
-- ───────────────────────────────────────────────────────────────────────

local function refreshTargets()
	table.clear(targets)
	for _, p in Players:GetPlayers() do
		if p ~= localPlayer and liveHumanoidOf(p) then
			table.insert(targets, p)
		end
	end
	if index > #targets then
		index = 1
	end
end

local function spectateCurrent()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if #targets == 0 then
		if nameLabel then
			nameLabel.Text = "Aucun survivant à observer"
		end
		return
	end
	if index > #targets then
		index = 1
	end
	local target = targets[index]
	local h = liveHumanoidOf(target)
	if h then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = h
	end
	if nameLabel then
		nameLabel.Text = "👁 " .. target.DisplayName
	end
end

-- Passe à la cible suivante (après recalcul : une cible a pu mourir/partir).
local function spectateNext()
	if not active then
		return
	end
	refreshTargets()
	if #targets == 0 then
		spectateCurrent()
		return
	end
	index += 1
	if index > #targets then
		index = 1
	end
	spectateCurrent()
end

local function onNextAction(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		spectateNext()
	end
	return Enum.ContextActionResult.Sink -- on consomme Tab pendant le spectateur
end

-- ───────────────────────────────────────────────────────────────────────
-- UI
-- ───────────────────────────────────────────────────────────────────────

local function buildGui()
	if gui then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "SignalLostSpectator"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.Enabled = false
	g.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Bandeau d'info (haut).
	local info = Instance.new("TextLabel")
	info.Size = UDim2.fromOffset(560, 30)
	info.Position = UDim2.new(0.5, -280, 0.04, 0)
	info.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	info.BackgroundTransparency = 0.5
	info.TextColor3 = Color3.fromRGB(235, 235, 235)
	info.TextScaled = false
	info.TextSize = 16
	info.Text = "SPECTATEUR — Appuyez sur Tab pour changer de vue"
	info.Parent = g

	-- Barre du bas : nom observé + bouton tactile « Suivant ».
	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(360, 48)
	bar.Position = UDim2.new(0.5, -180, 0.88, 0)
	bar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bar.BackgroundTransparency = 0.5
	bar.Parent = g

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(232, 40)
	label.Position = UDim2.fromOffset(8, 4)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.TextScaled = false
	label.TextSize = 18
	label.Text = "Mode spectateur"
	label.Parent = bar
	nameLabel = label

	local nextBtn = Instance.new("TextButton")
	nextBtn.Size = UDim2.fromOffset(108, 40)
	nextBtn.Position = UDim2.fromOffset(248, 4)
	nextBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	nextBtn.BackgroundTransparency = 0.3
	nextBtn.TextColor3 = Color3.fromRGB(235, 235, 235)
	nextBtn.TextScaled = true
	nextBtn.Text = "Suivant ▶"
	nextBtn.Parent = bar
	nextBtn.Activated:Connect(spectateNext)

	gui = g
end

-- ───────────────────────────────────────────────────────────────────────
-- Entrée / sortie
-- ───────────────────────────────────────────────────────────────────────

local function enterSpectator()
	if active then
		return
	end
	active = true
	buildGui()
	if gui then
		gui.Enabled = true
	end
	index = 1
	refreshTargets()
	spectateCurrent()
	-- Tab pour cycler (lié SEULEMENT pendant le spectateur → pas d'interférence).
	ContextActionService:BindAction(NEXT_ACTION, onNextAction, false, Enum.KeyCode.Tab)
end

local function exitSpectator()
	if not active then
		return
	end
	active = false
	if gui then
		gui.Enabled = false
	end
	ContextActionService:UnbindAction(NEXT_ACTION)
	-- Caméra remise sur son propre personnage (au respawn Roblox la réinit aussi).
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local h = ownHumanoid()
		if h then
			camera.CameraSubject = h
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Pilotage par lifeState (PlayerHud) + retour Lobby (RoundState)
-- ───────────────────────────────────────────────────────────────────────

local function onPlayerHud(state: Types.HudPlayerState)
	if type(state) ~= "table" then
		return
	end
	if state.lifeState == Types.LifeState.Dead or state.lifeState == Types.LifeState.Escaped then
		enterSpectator()
	else
		exitSpectator() -- redevenu Alive (respawn) → sortie
	end
end

local function onRoundState(state: Types.RoundState)
	if type(state) ~= "table" then
		return
	end
	if state.phase == Types.RoundPhase.Lobby then
		exitSpectator() -- retour Lobby : sortie propre quoi qu'il arrive
	end
end

function SpectatorController.init()
	if initialized then
		return
	end
	initialized = true
	Remotes.PlayerHud.OnClientEvent:Connect(onPlayerHud)
	Remotes.RoundState.OnClientEvent:Connect(onRoundState)
end

return SpectatorController
