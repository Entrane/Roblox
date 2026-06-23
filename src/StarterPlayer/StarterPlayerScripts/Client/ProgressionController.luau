--!strict
-- ProgressionController — UI progression (NON role-gated : XP/quêtes concernent
-- les deux rôles). Initialisé une fois par init.client. ScreenGui séparé du HUD.
--
-- Trois écoutes serveur→client :
--   - RoundState : pilote la VISIBILITÉ (panneau quêtes en Lobby/Starting ; écran
--     XP masqué hors Resolved) ;
--   - QuestState : remplit le panneau de quêtes ;
--   - XpResult   : remplit + montre l'écran XP de fin (+ bouton d'invitation si
--     la manche comptait < 4 joueurs).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)

local ProgressionController = {}

local localPlayer = Players.LocalPlayer

local screenGui: ScreenGui? = nil
local questPanel: Frame? = nil
local questLines: { TextLabel } = {}
local xpPanel: Frame? = nil
local xpGainedLabel: TextLabel? = nil
local xpBreakdownLabel: TextLabel? = nil
local xpLevelLabel: TextLabel? = nil
local xpFriendLabel: TextLabel? = nil
local inviteButton: TextButton? = nil

-- ───────────────────────────────────────────────────────────────────────
-- Fabriques
-- ───────────────────────────────────────────────────────────────────────

local function makeLabel(parent: Instance, pos: UDim2, size: UDim2, scaled: boolean): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.Size = size
	lbl.Position = pos
	lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.fromRGB(235, 235, 235)
	lbl.TextScaled = scaled
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.Text = ""
	lbl.Parent = parent
	return lbl
end

-- ───────────────────────────────────────────────────────────────────────
-- Handlers Remotes
-- ───────────────────────────────────────────────────────────────────────

local function onRoundState(state: Types.RoundState)
	if type(state) ~= "table" then
		return
	end
	if questPanel then
		questPanel.Visible = state.phase == Types.RoundPhase.Lobby or state.phase == Types.RoundPhase.Starting
	end
	-- L'écran XP n'a de sens qu'en Resolved : on le masque dès qu'on en sort.
	if xpPanel and state.phase ~= Types.RoundPhase.Resolved then
		xpPanel.Visible = false
	end
end

local function onQuestState(state: Types.QuestState)
	if type(state) ~= "table" or type(state.quests) ~= "table" then
		return
	end
	for i, line in questLines do
		local q = state.quests[i]
		if q then
			local mark = if q.complete then "✓" else string.format("%d/%d", q.progress, q.goal)
			line.Text = string.format("%s : %s  (+%d XP)", q.label, mark, q.xpReward)
			line.TextColor3 = if q.complete then Color3.fromRGB(120, 230, 120) else Color3.fromRGB(225, 225, 225)
		else
			line.Text = ""
		end
	end
end

local function onXpResult(result: Types.XpResult)
	if type(result) ~= "table" or not xpPanel then
		return
	end
	if xpGainedLabel then
		xpGainedLabel.Text = string.format("+%d XP", result.xpGained)
	end
	if xpBreakdownLabel then
		local b = result.breakdown
		xpBreakdownLabel.Text = string.format(
			"Participation %d · Évasion %d · Fusibles %d · Réa %d · Kills %d · Quêtes %d",
			b.participation, b.escaped, b.deposits, b.revives, b.kills, b.quests
		)
	end
	if xpLevelLabel then
		xpLevelLabel.Text = string.format("Niveau %d  (%d XP)", result.level, result.xp)
	end
	if xpFriendLabel then
		if result.friendCount > 0 then
			xpFriendLabel.Text = string.format("Bonus amis : +%d XP (%d ami(s) présent(s))", result.friendBonus, result.friendCount)
			xpFriendLabel.Visible = true
		else
			xpFriendLabel.Visible = false
		end
	end
	if inviteButton then
		inviteButton.Visible = result.suggestInvite == true
	end
	xpPanel.Visible = true
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

function ProgressionController.init()
	if screenGui then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SignalLostProgression"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Panneau de quêtes (gauche, visible en Lobby/Starting).
	local quests = Instance.new("Frame")
	quests.Name = "Quests"
	quests.Size = UDim2.fromOffset(360, 130)
	quests.Position = UDim2.fromOffset(12, 120)
	quests.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	quests.BackgroundTransparency = 0.45
	quests.Visible = false
	quests.Parent = gui
	questPanel = quests

	local title = makeLabel(quests, UDim2.fromOffset(8, 4), UDim2.fromOffset(344, 26), true)
	title.Text = "Quêtes du jour"
	title.TextColor3 = Color3.fromRGB(255, 235, 160)
	for i = 1, 3 do
		questLines[i] = makeLabel(quests, UDim2.fromOffset(8, 4 + i * 30), UDim2.fromOffset(344, 26), false)
		questLines[i].TextScaled = false
		questLines[i].TextSize = 16
	end

	-- Écran XP de fin (bas-centre, sous l'écran de résultat P2-8).
	local xp = Instance.new("Frame")
	xp.Name = "XpResult"
	xp.Size = UDim2.fromOffset(460, 170)
	xp.Position = UDim2.new(0.5, -230, 0.55, 0)
	xp.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	xp.BackgroundTransparency = 0.4
	xp.Visible = false
	xp.Parent = gui
	xpPanel = xp

	xpGainedLabel = makeLabel(xp, UDim2.fromOffset(10, 6), UDim2.fromOffset(440, 36), true)
	xpGainedLabel.TextColor3 = Color3.fromRGB(255, 235, 160)
	xpLevelLabel = makeLabel(xp, UDim2.fromOffset(10, 46), UDim2.fromOffset(440, 24), false)
	xpLevelLabel.TextSize = 18
	xpBreakdownLabel = makeLabel(xp, UDim2.fromOffset(10, 72), UDim2.fromOffset(440, 22), false)
	xpBreakdownLabel.TextSize = 14
	xpFriendLabel = makeLabel(xp, UDim2.fromOffset(10, 96), UDim2.fromOffset(440, 22), false)
	xpFriendLabel.TextSize = 15
	xpFriendLabel.TextColor3 = Color3.fromRGB(150, 210, 255)

	local invite = Instance.new("TextButton")
	invite.Name = "Invite"
	invite.Size = UDim2.fromOffset(440, 40)
	invite.Position = UDim2.fromOffset(10, 124)
	invite.BackgroundColor3 = Color3.fromRGB(45, 90, 60)
	invite.TextColor3 = Color3.fromRGB(235, 235, 235)
	invite.TextScaled = true
	invite.Text = "Invite tes amis !"
	invite.Visible = false
	invite.Parent = xp
	invite.Activated:Connect(function()
		pcall(function()
			SocialService:PromptGameInvite(localPlayer)
		end)
	end)
	inviteButton = invite

	screenGui = gui

	Remotes.RoundState.OnClientEvent:Connect(onRoundState)
	Remotes.QuestState.OnClientEvent:Connect(onQuestState)
	Remotes.XpResult.OnClientEvent:Connect(onXpResult)
end

return ProgressionController
