--!strict
-- HudController — Couche UI : boutons d'action par rôle + AFFICHAGE HUD (phase/
-- timer, fusibles x/5, stamina/batterie, statut "à terre/mort/évadé").
--
-- Les boutons d'action sont câblés par les controllers (qui FireServer). Les
-- AFFICHAGES, eux, sont alimentés par 3 Remotes serveur→client en LECTURE SEULE
-- (RoundState, FuseProgress, PlayerHud) auxquels ce module s'abonne dans init() —
-- c'est leur place naturelle (HUD pur). Cadence serveur ~10 Hz ; le timer est
-- décompté EN LOCAL entre deux pushes (fluide) et resynchronisé à chaque RoundState.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)

local HudController = {}

local localPlayer = Players.LocalPlayer

local screenGui: ScreenGui? = nil
local buttons: { [string]: TextButton } = {}

-- Éléments d'affichage (créés dans init()).
local roundLabel: TextLabel? = nil -- phase + timer
local fuseLabel: TextLabel? = nil -- "Fusibles x/5"
local statsFrame: Frame? = nil -- conteneur barres (survivant)
local staminaFill: Frame? = nil
local batteryFill: Frame? = nil
local statusLabel: TextLabel? = nil -- "À TERRE / MORT / ÉVADÉ"

-- État local du timer (resync sur chaque RoundState, décompté entre les pushes).
local roundPhase: Types.RoundPhase = Types.RoundPhase.Lobby
local localTime = 0

local SURVIVOR_GROUP = { "Sprint", "Torch" }
local ECHO_GROUP = { "Howl", "Frenzy" }

local LABELS: { [string]: string } = {
	Sprint = "Sprint",
	Torch = "Torche",
	Revive = "Réanimer",
	Howl = "Hurlement",
	Frenzy = "Frénésie",
}

-- ───────────────────────────────────────────────────────────────────────
-- Fabriques d'UI
-- ───────────────────────────────────────────────────────────────────────

local function makeButton(name: string, order: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Text = LABELS[name] or name
	btn.Size = UDim2.fromOffset(120, 60)
	btn.Position = UDim2.new(1, -132, 1, -(order * 68) - 12)
	btn.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
	btn.TextColor3 = Color3.fromRGB(235, 235, 235)
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Active = true
	btn.Visible = false
	return btn
end

local function makeLabel(name: string, pos: UDim2, size: UDim2): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Name = name
	lbl.Size = size
	lbl.Position = pos
	lbl.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	lbl.BackgroundTransparency = 0.5
	lbl.TextColor3 = Color3.fromRGB(235, 235, 235)
	lbl.TextScaled = true
	lbl.Text = ""
	return lbl
end

-- Barre = conteneur sombre + remplissage proportionnel (scale X). Renvoie le fill.
local function makeBar(parent: Instance, name: string, order: number, color: Color3): Frame
	local bg = Instance.new("Frame")
	bg.Name = name
	bg.Size = UDim2.fromOffset(180, 18)
	bg.Position = UDim2.fromOffset(12, order * 24)
	bg.BackgroundColor3 = Color3.fromRGB(25, 25, 28)
	bg.BorderSizePixel = 0
	bg.Parent = parent

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = bg
	return fill
end

-- ───────────────────────────────────────────────────────────────────────
-- Affichage : formatage + setters
-- ───────────────────────────────────────────────────────────────────────

local function formatRound(): string
	local t = math.max(0, math.floor(localTime))
	if roundPhase == Types.RoundPhase.Lobby then
		return "En attente de joueurs"
	elseif roundPhase == Types.RoundPhase.Starting then
		return string.format("Départ dans %ds", t)
	elseif roundPhase == Types.RoundPhase.Playing then
		return string.format("Temps : %d:%02d", t // 60, t % 60)
	elseif roundPhase == Types.RoundPhase.Resolved then
		return "Manche terminée"
	end
	return ""
end

local function refreshRoundLabel()
	if roundLabel then
		roundLabel.Text = formatRound()
	end
end

local function setStatus(lifeState: Types.PlayerLifeState)
	if not statusLabel then
		return
	end
	if lifeState == Types.LifeState.Downed then
		statusLabel.Text = "À TERRE"
		statusLabel.Visible = true
	elseif lifeState == Types.LifeState.Dead then
		statusLabel.Text = "MORT"
		statusLabel.Visible = true
	elseif lifeState == Types.LifeState.Escaped then
		statusLabel.Text = "ÉVADÉ"
		statusLabel.Visible = true
	else
		statusLabel.Visible = false -- Alive
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Abonnements aux Remotes HUD
-- ───────────────────────────────────────────────────────────────────────

local function onRoundState(state: Types.RoundState)
	if type(state) ~= "table" then
		return
	end
	roundPhase = state.phase
	localTime = state.timeRemaining -- resync (le Heartbeat décompte entre deux pushes)
	refreshRoundLabel()
end

local function onFuseProgress(progress: Types.FuseProgress)
	if type(progress) ~= "table" or not fuseLabel then
		return
	end
	fuseLabel.Text = string.format("Fusibles %d/%d", progress.collected, progress.required)
end

local function onPlayerHud(state: Types.HudPlayerState)
	if type(state) ~= "table" then
		return
	end
	if staminaFill then
		staminaFill.Size = UDim2.fromScale(math.clamp(state.stamina / GameConfig.Stamina.Max, 0, 1), 1)
	end
	if batteryFill then
		batteryFill.Size = UDim2.fromScale(math.clamp(state.battery / GameConfig.Torch.BatteryMax, 0, 1), 1)
	end
	setStatus(state.lifeState)
end

-- Décompte local du timer entre deux pushes (le serveur ne tourne le timer qu'en
-- Starting/Playing/Resolved ; en Lobby il est figé → on n'enlève rien).
local function onHeartbeat(dt: number)
	if roundPhase ~= Types.RoundPhase.Lobby and localTime > 0 then
		localTime = math.max(0, localTime - dt)
		refreshRoundLabel()
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

function HudController.init()
	if screenGui then
		return -- idempotent
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SignalLostHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Boutons d'action (bas-droite).
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.Size = UDim2.fromScale(1, 1)
	actions.BackgroundTransparency = 1
	actions.Parent = gui

	buttons.Sprint = makeButton("Sprint", 3)
	buttons.Torch = makeButton("Torch", 2)
	buttons.Revive = makeButton("Revive", 1)
	buttons.Howl = makeButton("Howl", 2)
	buttons.Frenzy = makeButton("Frenzy", 1)
	for _, btn in buttons do
		btn.Parent = actions
	end

	-- Barre du haut (tous rôles) : phase/timer à gauche, fusibles à droite.
	roundLabel = makeLabel("Round", UDim2.new(0.5, -210, 0, 8), UDim2.fromOffset(260, 32))
	roundLabel.Parent = gui
	fuseLabel = makeLabel("Fuses", UDim2.new(0.5, 60, 0, 8), UDim2.fromOffset(150, 32))
	fuseLabel.Parent = gui

	-- Barres stamina/batterie (survivant ; cachées par défaut, gérées par setRole).
	local stats = Instance.new("Frame")
	stats.Name = "Stats"
	stats.Size = UDim2.fromOffset(192, 60)
	stats.Position = UDim2.new(0, 0, 1, -76)
	stats.BackgroundTransparency = 1
	stats.Visible = false
	stats.Parent = gui
	statsFrame = stats
	staminaFill = makeBar(stats, "Stamina", 0, Color3.fromRGB(90, 200, 90))
	batteryFill = makeBar(stats, "Battery", 1, Color3.fromRGB(230, 210, 80))

	-- Overlay d'état (centre) : "À TERRE / MORT / ÉVADÉ".
	local status = makeLabel("Status", UDim2.new(0.5, -150, 0.42, 0), UDim2.fromOffset(300, 48))
	status.TextColor3 = Color3.fromRGB(255, 90, 90)
	status.Visible = false
	status.Parent = gui
	statusLabel = status

	screenGui = gui

	-- Abonnements HUD + décompte local.
	Remotes.RoundState.OnClientEvent:Connect(onRoundState)
	Remotes.FuseProgress.OnClientEvent:Connect(onFuseProgress)
	Remotes.PlayerHud.OnClientEvent:Connect(onPlayerHud)
	RunService.Heartbeat:Connect(onHeartbeat)
end

-- ───────────────────────────────────────────────────────────────────────
-- Visibilité par rôle
-- ───────────────────────────────────────────────────────────────────────

function HudController.setRole(role: Types.Role?)
	local function setGroup(names: { string }, visible: boolean)
		for _, n in names do
			local b = buttons[n]
			if b then
				b.Visible = visible
			end
		end
	end
	setGroup(SURVIVOR_GROUP, role == Types.Role.Survivor)
	setGroup(ECHO_GROUP, role == Types.Role.Echo)
	if buttons.Revive then
		buttons.Revive.Visible = false -- contextuel (ReviveController)
	end
	-- Barres + statut : survivant uniquement (l'Écho ne reçoit pas PlayerHud).
	if statsFrame then
		statsFrame.Visible = role == Types.Role.Survivor
	end
	if statusLabel and role ~= Types.Role.Survivor then
		statusLabel.Visible = false
	end
end

function HudController.getButton(name: string): TextButton?
	return buttons[name]
end

function HudController.setReviveVisible(visible: boolean)
	if buttons.Revive then
		buttons.Revive.Visible = visible
	end
end

-- Reflète l'état d'une capacité Écho sur son bouton (couleur + décompte).
function HudController.setAbilityState(abilityId: Types.AbilityId, cooldownRemaining: number, activeRemaining: number)
	local name: string? = nil
	if abilityId == Types.AbilityId.Howl then
		name = "Howl"
	elseif abilityId == Types.AbilityId.Frenzy then
		name = "Frenzy"
	end
	if not name then
		return
	end
	local btn = buttons[name]
	if not btn then
		return
	end
	local label = LABELS[name] or name
	if cooldownRemaining > 0 then
		btn.Text = string.format("%s\n%ds", label, math.ceil(cooldownRemaining))
		btn.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
	elseif activeRemaining > 0 then
		btn.Text = label .. "\n(actif)"
		btn.BackgroundColor3 = Color3.fromRGB(30, 70, 40)
	else
		btn.Text = label
		btn.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
	end
end

return HudController
