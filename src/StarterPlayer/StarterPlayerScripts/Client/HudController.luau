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

-- Indicateur de bonus actif de l'Écho : un cercle par capacité qui RÉTRÉCIT selon
-- le temps restant du bonus (Frénésie = plus rapide, Hurlement = voit plus loin).
type BuffChip = { chip: Frame, circle: Frame, active: number, total: number }
local buffChips: { [string]: BuffChip } = {}

local LABELS: { [string]: string } = {
	Sprint = "Sprint",
	Torch = "Torche",
	Revive = "Réanimer",
	Howl = "Hurlement",
	Frenzy = "Frénésie",
	Melee = "Attaquer",
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
	lbl.BackgroundColor3 = Color3.fromRGB(9, 11, 15)
	lbl.BackgroundTransparency = 0.2
	lbl.TextColor3 = Color3.fromRGB(170, 230, 218)
	lbl.Font = Enum.Font.Code
	lbl.TextScaled = true
	lbl.Text = ""
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = lbl
	local st = Instance.new("UIStroke"); st.Color = Color3.fromRGB(38, 110, 100); st.Thickness = 1; st.Transparency = 0.25; st.Parent = lbl
	local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8); pad.Parent = lbl
	return lbl
end

-- Barre = conteneur sombre + remplissage proportionnel (scale X). Renvoie le fill.
local function makeBar(parent: Instance, name: string, order: number, color: Color3, label: string, icon: string): Frame
	local holder = Instance.new("Frame")
	holder.Name = name .. "Holder"
	holder.Size = UDim2.fromOffset(214, 24)
	holder.Position = UDim2.fromOffset(0, order * 30)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local ic = Instance.new("TextLabel")
	ic.Size = UDim2.fromOffset(24, 24)
	ic.BackgroundTransparency = 1
	ic.Text = icon
	ic.TextScaled = true
	ic.TextColor3 = color
	ic.Parent = holder

	local bg = Instance.new("Frame")
	bg.Name = name
	bg.Size = UDim2.fromOffset(184, 16)
	bg.Position = UDim2.fromOffset(30, 4)
	bg.BackgroundColor3 = Color3.fromRGB(16, 17, 21)
	bg.BorderSizePixel = 0
	bg.Parent = holder
	local bgc = Instance.new("UICorner"); bgc.CornerRadius = UDim.new(0, 4); bgc.Parent = bg
	local bgs = Instance.new("UIStroke"); bgs.Color = Color3.fromRGB(58, 62, 70); bgs.Thickness = 1; bgs.Transparency = 0.2; bgs.Parent = bg

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = bg
	local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(0, 4); fc.Parent = fill
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(color, Color3.new(color.R * 0.55, color.G * 0.55, color.B * 0.55))
	grad.Rotation = 90
	grad.Parent = fill
	local fs = Instance.new("UIStroke"); fs.Color = color; fs.Thickness = 1; fs.Transparency = 0.35; fs.Parent = fill

	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.fromScale(1, 1)
	txt.BackgroundTransparency = 1
	txt.Text = label
	txt.Font = Enum.Font.Code
	txt.TextSize = 11
	txt.TextColor3 = Color3.fromRGB(235, 240, 245)
	txt.TextXAlignment = Enum.TextXAlignment.Left
	txt.TextTransparency = 0.1
	txt.ZIndex = 3
	txt.Parent = bg
	local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 7); pad.Parent = txt

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
-- Lampe torche en CÔNE, orientée vers le REGARD (caméra). Un petit émetteur
-- invisible suit la CFrame de la caméra chaque frame ; la SpotLight (Face Front =
-- -Z = direction du regard) projette le cône devant le joueur. Local, non répliqué.
local torchEmitter: Part? = nil
local torchConn: RBXScriptConnection? = nil

local function ensureTorchEmitter(): Part
	if torchEmitter and torchEmitter.Parent then
		return torchEmitter
	end
	local emitter = Instance.new("Part")
	emitter.Name = "TorchEmitter"
	emitter.Size = Vector3.new(0.2, 0.2, 0.2)
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.Transparency = 1
	emitter.Massless = true
	local spot = Instance.new("SpotLight")
	spot.Name = "Beam"
	spot.Face = Enum.NormalId.Front
	spot.Angle = 70
	spot.Range = 55
	spot.Brightness = 3.2
	spot.Color = Color3.fromRGB(255, 244, 214)
	spot.Shadows = true
	spot.Enabled = false
	spot.Parent = emitter
	emitter.Parent = workspace.CurrentCamera or workspace
	torchEmitter = emitter
	if not torchConn then
		torchConn = RunService.RenderStepped:Connect(function()
			local cam = workspace.CurrentCamera
			if torchEmitter and torchEmitter.Parent and cam then
				torchEmitter.CFrame = cam.CFrame
			end
		end)
	end
	return emitter
end

local function setTorchLight(on: boolean)
	local emitter = ensureTorchEmitter()
	local spot = emitter:FindFirstChildOfClass("SpotLight")
	if spot then
		spot.Enabled = on
	end
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
-- Construit l'indicateur de bonus (bas-centre) : 2 pastilles circulaires.
local function buildBuffIndicator(parent: Instance)
	local defs = {
		{ name = "Frenzy", icon = "⚡", color = Color3.fromRGB(240, 140, 30), total = GameConfig.Echo.Frenzy.Duration },
		{ name = "Howl", icon = "👁", color = Color3.fromRGB(80, 180, 240), total = GameConfig.Echo.Howl.RevealDuration },
	}
	local container = Instance.new("Frame")
	container.Name = "Buffs"
	container.AnchorPoint = Vector2.new(0.5, 1)
	container.Position = UDim2.new(0.5, 0, 1, -14)
	container.Size = UDim2.fromOffset(170, 72)
	container.BackgroundTransparency = 1
	container.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 18)
	layout.Parent = container

	for _, def in defs do
		local chip = Instance.new("Frame")
		chip.Name = def.name
		chip.Size = UDim2.fromOffset(64, 64)
		chip.BackgroundTransparency = 1
		chip.Visible = false
		chip.Parent = container

		local ring = Instance.new("Frame")
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.Size = UDim2.fromOffset(60, 60)
		ring.BackgroundTransparency = 1
		ring.Parent = chip
		local rc = Instance.new("UICorner")
		rc.CornerRadius = UDim.new(0.5, 0)
		rc.Parent = ring
		local rs = Instance.new("UIStroke")
		rs.Color = def.color
		rs.Transparency = 0.5
		rs.Thickness = 2
		rs.Parent = ring

		local circle = Instance.new("Frame")
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.Position = UDim2.fromScale(0.5, 0.5)
		circle.Size = UDim2.fromOffset(56, 56)
		circle.BackgroundColor3 = def.color
		circle.BackgroundTransparency = 0.3
		circle.Parent = chip
		local cc = Instance.new("UICorner")
		cc.CornerRadius = UDim.new(0.5, 0)
		cc.Parent = circle

		local icon = Instance.new("TextLabel")
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromOffset(38, 38)
		icon.BackgroundTransparency = 1
		icon.Text = def.icon
		icon.TextScaled = true
		icon.TextColor3 = Color3.fromRGB(255, 255, 255)
		icon.ZIndex = 2
		icon.Parent = chip

		buffChips[def.name] = { chip = chip, circle = circle, active = 0, total = def.total }
	end
end

-- Met à jour les cercles : décompte local + rétrécissement proportionnel.
local function updateBuffs(dt: number)
	for _, b in buffChips do
		if b.active > 0 then
			b.active = math.max(0, b.active - dt)
			local ratio = if b.total > 0 then b.active / b.total else 0
			local size = 10 + 46 * ratio
			b.circle.Size = UDim2.fromOffset(size, size)
			b.chip.Visible = b.active > 0
		elseif b.chip.Visible then
			b.chip.Visible = false
		end
	end
end

local function onHeartbeat(dt: number)
	updateBuffs(dt)
	if roundPhase ~= Types.RoundPhase.Lobby and localTime > 0 then
		localTime = math.max(0, localTime - dt)
		refreshRoundLabel()
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

local function buildVignette(gui: ScreenGui)
	local v = Instance.new("Frame")
	v.Name = "Vignette"
	v.Size = UDim2.fromScale(1, 1)
	v.BackgroundTransparency = 1
	v.ZIndex = 0
	v.Parent = gui
	local function strip(anchorY: number, posY: number, rot: number)
		local f = Instance.new("Frame")
		f.Size = UDim2.new(1, 0, 0, 160)
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.new(0, 0, posY, 0)
		f.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		f.BorderSizePixel = 0
		f.ZIndex = 0
		f.Parent = v
		local g = Instance.new("UIGradient")
		g.Rotation = rot
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
	end
	strip(0, 0, 90)
	strip(1, 1, 270)
end

function HudController.init()
	if screenGui then
		return -- idempotent
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SignalLostHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	buildVignette(gui)

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
	buttons.Melee = makeButton("Melee", 3) -- Écho, contextuel (proximité)
	for _, btn in buttons do
		btn.Parent = actions
	end

	buildBuffIndicator(gui)

	-- Barre du haut (tous rôles) : phase/timer à gauche, fusibles à droite.
	roundLabel = makeLabel("Round", UDim2.new(0.5, -210, 0, 8), UDim2.fromOffset(260, 32))
	roundLabel.Parent = gui
	fuseLabel = makeLabel("Fuses", UDim2.new(0.5, 60, 0, 8), UDim2.fromOffset(150, 32))
	fuseLabel.Parent = gui

	-- Barres stamina/batterie (survivant ; cachées par défaut, gérées par setRole).
	local stats = Instance.new("Frame")
	stats.Name = "Stats"
	stats.Size = UDim2.fromOffset(220, 72)
	stats.Position = UDim2.new(0, 12, 1, -92)
	stats.BackgroundTransparency = 1
	stats.Visible = false
	stats.Parent = gui
	statsFrame = stats
	staminaFill = makeBar(stats, "Stamina", 0, Color3.fromRGB(80, 210, 130), "ENDURANCE", "⚡")
	batteryFill = makeBar(stats, "Battery", 1, Color3.fromRGB(235, 205, 80), "LAMPE", "🔋")

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

	-- Écran de fin (HAUT-centre) : qui a gagné. Remonté en tête pour laisser le
	-- centre au leaderboard de fin de manche (ProgressionController). Tous rôles
	-- (RoundState est FireAllClients). Masqué hors Resolved.
	local result = makeLabel("Result", UDim2.new(0.5, -260, 0.06, 0), UDim2.fromOffset(520, 70))
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
	if buttons.Melee then
		buttons.Melee.Visible = false -- contextuel Écho (EchoController.client, proximité)
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

function HudController.setMeleeVisible(visible: boolean)
	if buttons.Melee then
		buttons.Melee.Visible = visible
	end
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

	-- Indicateur de bonus : (re)synchronise le temps actif depuis le serveur.
	local b = buffChips[name]
	if b then
		b.active = activeRemaining
		if activeRemaining <= 0 then
			b.chip.Visible = false
		end
	end
end

return HudController
