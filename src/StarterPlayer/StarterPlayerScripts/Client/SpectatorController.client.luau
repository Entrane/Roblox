--!strict
-- SpectatorController (client) — LocalScript AUTONOME (le suffixe « .client » en
-- fait un LocalScript côté Rojo, non requérable, comme EchoController.client).
--
-- Quand le joueur local est Dead OU Escaped (lifeState reçu via PlayerHud), il
-- passe en mode SPECTATEUR : la caméra suit un survivant encore en vie, avec une
-- barre « ◀  👁 Nom  ▶ » pour changer de cible. Il en SORT au respawn (lifeState
-- redevient Alive) — un Downed n'est PAS spectateur (il peut être réanimé).
--
-- ─── 100 % CLIENT, AUCUNE DONNÉE SERVEUR SUPPLÉMENTAIRE ──────────────────
-- Les personnages sont déjà répliqués par Roblox : un joueur éliminé (hors
-- manche) peut légitimement les observer. On ne fait que déplacer la caméra
-- (CameraSubject) sur des persos existants. L'info secrète de l'Écho
-- (écholocation) n'est JAMAIS concernée ici — c'est un autre canal, ciblé.
--
-- ⚠️ À VALIDER DANS STUDIO : comportement caméra (CameraSubject/CameraType),
-- respawn, et rendu tactile de la barre sur mobile.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)

local localPlayer = Players.LocalPlayer

local active = false
local targets: { Player } = {} -- survivants observables (recalculés à chaque action)
local index = 1
local gui: ScreenGui? = nil
local nameLabel: TextLabel? = nil

-- ───────────────────────────────────────────────────────────────────────
-- Helpers monde (défensifs : perso pas chargé / mort)
-- ───────────────────────────────────────────────────────────────────────

local function ownHumanoid(): Humanoid?
	local char = localPlayer.Character
	if not char then
		return nil
	end
	return char:FindFirstChildOfClass("Humanoid")
end

-- Humanoid d'un AUTRE joueur s'il est vivant (Health > 0), sinon nil → exclu de
-- la liste d'observation.
local function aliveHumanoidOf(player: Player): Humanoid?
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

-- Recalcule la liste des survivants observables (autres joueurs vivants).
local function refreshTargets()
	table.clear(targets)
	for _, p in Players:GetPlayers() do
		if p ~= localPlayer and aliveHumanoidOf(p) then
			table.insert(targets, p)
		end
	end
	if index > #targets then
		index = 1
	end
	if index < 1 then
		index = 1
	end
end

-- Pointe la caméra sur la cible courante (CameraSubject). Vide → message.
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
	local h = aliveHumanoidOf(target)
	if h then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = h
	end
	if nameLabel then
		nameLabel.Text = "👁 " .. target.DisplayName
	end
end

-- Change de cible (delta = +1 / -1) après recalcul (une cible a pu mourir/partir).
local function cycle(delta: number)
	refreshTargets()
	if #targets == 0 then
		spectateCurrent()
		return
	end
	index += delta
	if index > #targets then
		index = 1
	elseif index < 1 then
		index = #targets
	end
	spectateCurrent()
end

-- ───────────────────────────────────────────────────────────────────────
-- UI (barre bas-centre, créée à la volée)
-- ───────────────────────────────────────────────────────────────────────

local function makeButton(parent: Instance, text: string, posX: number): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(48, 40)
	b.Position = UDim2.fromOffset(posX, 4)
	b.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	b.BackgroundTransparency = 0.3
	b.TextColor3 = Color3.fromRGB(235, 235, 235)
	b.TextScaled = true
	b.Text = text
	b.Parent = parent
	return b
end

local function ensureGui()
	if gui then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "SignalLostSpectator"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.Enabled = false
	g.Parent = localPlayer:WaitForChild("PlayerGui")

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromOffset(360, 48)
	bar.Position = UDim2.new(0.5, -180, 0.88, 0)
	bar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bar.BackgroundTransparency = 0.5
	bar.Parent = g

	local prev = makeButton(bar, "◀", 4)
	local next = makeButton(bar, "▶", 308)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(248, 40)
	label.Position = UDim2.fromOffset(56, 4)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(235, 235, 235)
	label.TextScaled = false
	label.TextSize = 18
	label.Text = "Mode spectateur"
	label.Parent = bar
	nameLabel = label

	prev.Activated:Connect(function()
		cycle(-1)
	end)
	next.Activated:Connect(function()
		cycle(1)
	end)

	gui = g
end

-- ───────────────────────────────────────────────────────────────────────
-- Entrée / sortie du mode
-- ───────────────────────────────────────────────────────────────────────

local function enterSpectator()
	if active then
		return
	end
	active = true
	ensureGui()
	if gui then
		gui.Enabled = true
	end
	index = 1
	refreshTargets()
	spectateCurrent()
end

local function exitSpectator()
	if not active then
		return
	end
	active = false
	if gui then
		gui.Enabled = false
	end
	-- Restaure la caméra sur son propre personnage (au respawn, Roblox la réinit
	-- de toute façon ; on couvre le cas où le perso est déjà là).
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
-- Pilotage par le lifeState reçu (PlayerHud, ciblé au joueur)
-- ───────────────────────────────────────────────────────────────────────

local function onPlayerHud(state: Types.HudPlayerState)
	if type(state) ~= "table" then
		return
	end
	if state.lifeState == Types.LifeState.Dead or state.lifeState == Types.LifeState.Escaped then
		enterSpectator()
	else
		exitSpectator()
	end
end

Remotes.PlayerHud.OnClientEvent:Connect(onPlayerHud)
