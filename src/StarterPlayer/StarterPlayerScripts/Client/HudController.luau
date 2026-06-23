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
local resultLabel: TextLabel? = nil -- écran de fin (phase Resolved)
local onboardingLabel: TextLabel? = nil -- objectif affiché 5 s au démarrage
local onboardingToken = 0 -- invalide un timer d'onboarding obsolète (changement de rôle)
local phaseCenterLabel: TextLabel? = nil -- centre : attente lobby / décompte Starting

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
	-- Affichage central selon la phase (lobby/attente, décompte de départ).
	-- Mis à jour à chaque push RoundState ET à chaque Heartbeat (décompte fluide
	-- de Starting), donc resync + fluidité comme le timer Playing.
	if phaseCenterLabel then
		if roundPhase == Types.RoundPhase.Lobby then
			phaseCenterLabel.Text = "En attente de joueurs..."
			phaseCenterLabel.Visible = true
		elseif roundPhase == Types.RoundPhase.Starting then
			phaseCenterLabel.Text = string.format("Départ dans %ds", math.max(0, math.ceil(localTime)))
			phaseCenterLabel.Visible = true
		else
			phaseCenterLabel.Visible = false -- Playing (onboarding) / Resolved (résultat)
		end
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

-- Écran de fin : affiché UNIQUEMENT en phase Resolved, masqué partout ailleurs.
-- winner est garanti non-nil en Resolved (invariant RoundManager.getState).
local function refreshResult(winner: Types.Faction?)
	if not resultLabel then
		return
	end
	if roundPhase == Types.RoundPhase.Resolved then
		if winner == Types.Faction.Survivors then
			resultLabel.Text = "Les survivants s'échappent !"
		elseif winner == Types.Faction.Echo then
			resultLabel.Text = "L'Écho l'emporte."
		else
			resultLabel.Text = ""
		end
		resultLabel.Visible = resultLabel.Text ~= ""
		if statusLabel then
			statusLabel.Visible = false -- l'écran de fin prime sur le statut courant
		end
	else
		resultLabel.Visible = false
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
	refreshResult(state.winner)
end

local function onFuseProgress(progress: Types.FuseProgress)
	if type(progress) ~= "table" or not fuseLabel then
		return
	end
	fuseLabel.Text = string.format("Fusibles %d/%d", progress.collected, progress.required)
end

-- Torche AUTORITAIRE : la PointLight (locale, non répliquée) suit l'état serveur
-- torchOn reçu, pas l'intention client. Si la batterie se vide serveur-side,
-- torchOn passe false → la lumière s'éteint correctement.
local function setTorchLight(on: boolean)
	local character = localPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local light = hrp:FindFirstChild("TorchLight")
	if not light then
		if not on then
			return
		end
		local pl = Instance.new("PointLight")
		pl.Name = "TorchLight"
		pl.Brightness = 2.5
		pl.Range = 18
		pl.Color = Color3.fromRGB(255, 244, 214)
		pl.Parent = hrp
		light = pl
	end
	(light :: PointLight).Enabled = on
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
	setTorchLight(state.torchOn)
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

	-- Onboarding (objectif), affiché ~5 s au démarrage de manche, centré haut.
	local onboarding = makeLabel("Onboarding", UDim2.new(0.5, -300, 0.28, 0), UDim2.fromOffset(600, 56))
	onboarding.TextColor3 = Color3.fromRGB(220, 235, 255)
	onboarding.Visible = false
	onboarding.Parent = gui
	onboardingLabel = onboarding

	-- Affichage central de phase (attente lobby / décompte de départ). Centré,
	-- discret. Ne coexiste pas dans le temps avec onboarding (Playing) / résultat
	-- (Resolved) — affiché seulement en Lobby/Starting.
	local phaseCenter = makeLabel("PhaseCenter", UDim2.new(0.5, -250, 0.4, -20), UDim2.fromOffset(500, 40))
	phaseCenter.BackgroundTransparency = 0.7
	phaseCenter.Visible = false
	phaseCenter.Parent = gui
	phaseCenterLabel = phaseCenter

	-- Écran de fin (centre, plus grand) : qui a gagné. Tous rôles (RoundState
	-- est FireAllClients). Masqué hors Resolved.
	local result = makeLabel("Result", UDim2.new(0.5, -260, 0.4, -40), UDim2.fromOffset(520, 80))
	result.TextColor3 = Color3.fromRGB(255, 235, 160)
	result.Visible = false
	result.Parent = gui
	resultLabel = result

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

-- Affiche l'objectif du rôle ~5 s puis masque. Le token invalide un timer
-- précédent si le rôle change avant la fin des 5 s.
local function showOnboarding(role: Types.Role?)
	if not onboardingLabel then
		return
	end
	local text: string? = nil
	if role == Types.Role.Survivor then
		text = "Trouvez les 5 fusibles, alimentez le générateur et fuyez !"
	elseif role == Types.Role.Echo then
		text = "Traque les survivants. Empêche-les de s'échapper."
	end
	if not text then
		onboardingLabel.Visible = false
		return
	end
	onboardingLabel.Text = text
	onboardingLabel.Visible = true
	onboardingToken += 1
	local myToken = onboardingToken
	task.delay(5, function()
		if myToken == onboardingToken and onboardingLabel then
			onboardingLabel.Visible = false
		end
	end)
end

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
	if role ~= Types.Role.Survivor then
		setTorchLight(false) -- pas de torche pour l'Écho (évite une lumière fantôme)
	end
	showOnboarding(role) -- objectif du rôle, 5 s
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
