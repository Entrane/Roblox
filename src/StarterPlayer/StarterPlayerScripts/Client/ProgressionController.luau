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
local questLevelLabel: TextLabel? = nil -- « Niveau N — Titre » (lobby)
local questLines: { TextLabel } = {}
local xpPanel: Frame? = nil
local xpGainedLabel: TextLabel? = nil
local xpTitleLabel: TextLabel? = nil -- titre actif / « Titre débloqué : X ! »
local xpBreakdownLabel: TextLabel? = nil
local xpStatsLabel: TextLabel? = nil -- stats brutes de la manche
local xpLevelLabel: TextLabel? = nil
local xpFriendLabel: TextLabel? = nil
local inviteButton: TextButton? = nil

-- Leaderboard de fin de manche (centre). Lignes pré-créées (≤5 joueurs).
local leaderboardPanel: Frame? = nil
type LbRow = { frame: Frame, label: TextLabel, stroke: UIStroke }
local lbRows: { LbRow } = {}
local LB_MAX_ROWS = 5

-- Panneau « Titres » (lobby) : sélection manuelle du titre actif.
local titlesPanel: Frame? = nil
local titlesScroll: ScrollingFrame? = nil
local titleButtons: { TextButton } = {}
local titleFlashLabel: TextLabel? = nil
local lastActiveTitle: string? = nil -- pour détecter un changement (flash)
local titlesInitialized = false -- pas de flash au tout premier QuestState
local flashToken = 0 -- invalide un flash obsolète (sélections rapprochées)

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
-- Titres : reconstruction des boutons + flash de confirmation
-- ───────────────────────────────────────────────────────────────────────

-- Flash transitoire « ✓ Titre équipé » (~1,5 s). Le token invalide un flash
-- précédent si l'on enchaîne les sélections (pas de clignotement résiduel).
local function showTitleFlash()
	if not titleFlashLabel then
		return
	end
	flashToken += 1
	local myToken = flashToken
	titleFlashLabel.Text = "✓ Titre équipé"
	titleFlashLabel.Visible = true
	task.delay(1.5, function()
		if flashToken == myToken and titleFlashLabel then
			titleFlashLabel.Visible = false
		end
	end)
end

-- Reconstruit la liste de boutons depuis les titres possédés ; surligne l'actif.
-- Chaque bouton émet SetActiveTitle (revalidé serveur). On reconstruit à chaque
-- QuestState (la liste peut grandir) : simple et sûr (≤ ~10 titres).
local function rebuildTitles(unlocked: { string }, active: string?)
	local scroll = titlesScroll
	if not scroll then
		return
	end
	for _, b in titleButtons do
		b:Destroy()
	end
	table.clear(titleButtons)
	local count = 0
	for _, t in unlocked do
		count += 1
		local btn = Instance.new("TextButton")
		btn.Name = "Title_" .. count
		btn.Size = UDim2.new(1, -8, 0, 28)
		btn.BackgroundColor3 = if t == active then Color3.fromRGB(45, 90, 60) else Color3.fromRGB(40, 40, 48)
		btn.BackgroundTransparency = 0.2
		btn.BorderSizePixel = 0
		btn.TextColor3 = Color3.fromRGB(235, 235, 235)
		btn.TextScaled = false
		btn.TextSize = 15
		btn.Text = t
		btn.Parent = scroll
		local captured = t
		btn.Activated:Connect(function()
			Remotes.SetActiveTitle:FireServer(captured)
		end)
		table.insert(titleButtons, btn)
	end
	-- CanvasSize = hauteur du contenu (28 + 4 de padding par ligne).
	scroll.CanvasSize = UDim2.fromOffset(0, count * 32)
end

-- ───────────────────────────────────────────────────────────────────────
-- Handlers Remotes
-- ───────────────────────────────────────────────────────────────────────

local function onRoundState(state: Types.RoundState)
	if type(state) ~= "table" then
		return
	end
	local inLobby = state.phase == Types.RoundPhase.Lobby or state.phase == Types.RoundPhase.Starting
	if questPanel then
		questPanel.Visible = inLobby
	end
	if titlesPanel then
		titlesPanel.Visible = inLobby -- choix du titre : lobby seulement
	end
	-- Le leaderboard n'a de sens qu'en Resolved : on le masque dès qu'on en sort.
	if leaderboardPanel and state.phase ~= Types.RoundPhase.Resolved then
		leaderboardPanel.Visible = false
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
	if questLevelLabel then
		local title = state.activeTitle
		if type(title) == "string" and title ~= "" then
			questLevelLabel.Text = string.format("Niveau %d — %s", state.level, title)
		else
			questLevelLabel.Text = string.format("Niveau %d", state.level)
		end
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

	-- Titres : reconstruit la liste + surligne l'actif. Flash de confirmation si
	-- le titre actif a CHANGÉ (hors tout premier état = chargement initial).
	local unlocked: { string } = if type(state.unlockedTitles) == "table" then state.unlockedTitles else {}
	rebuildTitles(unlocked, state.activeTitle)
	if titlesInitialized and state.activeTitle ~= lastActiveTitle then
		showTitleFlash()
	end
	lastActiveTitle = state.activeTitle
	titlesInitialized = true
end

local function onXpResult(result: Types.XpResult)
	if type(result) ~= "table" or not xpPanel then
		return
	end
	if xpGainedLabel then
		xpGainedLabel.Text = string.format("+%d XP", result.xpGained)
	end
	-- Titre : un nouveau débloqué (mis en avant) sinon le titre actif courant.
	if xpTitleLabel then
		local newTitles = result.newTitles
		if type(newTitles) == "table" and #newTitles > 0 then
			xpTitleLabel.Text = string.format("🏆 Titre débloqué : %s !", newTitles[#newTitles])
			xpTitleLabel.TextColor3 = Color3.fromRGB(255, 215, 90)
			xpTitleLabel.Visible = true
		elseif type(result.activeTitle) == "string" and result.activeTitle ~= "" then
			xpTitleLabel.Text = string.format("Titre : %s", result.activeTitle)
			xpTitleLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
			xpTitleLabel.Visible = true
		else
			xpTitleLabel.Visible = false
		end
	end
	if xpBreakdownLabel then
		local b = result.breakdown
		xpBreakdownLabel.Text = string.format(
			"Participation %d · Évasion %d · Fusibles %d · Réa %d · Kills %d · Quêtes %d",
			b.participation, b.escaped, b.deposits, b.revives, b.kills, b.quests
		)
	end
	if xpStatsLabel then
		local s = result.stats
		xpStatsLabel.Text = string.format(
			"Manche : Fusibles %d · Réa %d · Kills %d · Survie %d s",
			s.deposits, s.revives, s.kills, s.survivalSeconds
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

-- Reçu UNE fois au Resolved (FireAllClients) : remplit le classement trié.
-- Faction gagnante teintée ; ligne du joueur local encadrée (UIStroke).
local function onRoundLeaderboard(board: Types.RoundLeaderboard)
	if type(board) ~= "table" or type(board.entries) ~= "table" or not leaderboardPanel then
		return
	end
	for i, row in lbRows do
		local e = board.entries[i]
		if e then
			row.frame.Visible = true
			local role = if e.isEcho then "Écho" else "Survivant"
			row.label.Text = string.format(
				"%d. %s  [%s]  +%d XP   K%d · F%d · R%d · %ds",
				i, e.name, role, e.xpGained, e.kills, e.deposits, e.revives, e.survivalSeconds
			)
			-- Teinte faction gagnante.
			if e.won then
				row.frame.BackgroundColor3 = Color3.fromRGB(40, 90, 50)
				row.frame.BackgroundTransparency = 0.4
				row.label.TextColor3 = Color3.fromRGB(190, 240, 190)
			else
				row.frame.BackgroundTransparency = 1
				row.label.TextColor3 = Color3.fromRGB(225, 225, 225)
			end
			-- Encadré pour la ligne du joueur local.
			row.stroke.Transparency = if e.userId == localPlayer.UserId then 0 else 1
		else
			row.frame.Visible = false
		end
	end
	leaderboardPanel.Visible = true
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
	quests.Size = UDim2.fromOffset(360, 156)
	quests.Position = UDim2.fromOffset(12, 120)
	quests.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	quests.BackgroundTransparency = 0.45
	quests.Visible = false
	quests.Parent = gui
	questPanel = quests

	local title = makeLabel(quests, UDim2.fromOffset(8, 4), UDim2.fromOffset(344, 26), true)
	title.Text = "Quêtes du jour"
	title.TextColor3 = Color3.fromRGB(255, 235, 160)
	-- Niveau + titre actif (sous le titre du panneau).
	questLevelLabel = makeLabel(quests, UDim2.fromOffset(8, 30), UDim2.fromOffset(344, 22), false)
	questLevelLabel.TextSize = 16
	questLevelLabel.TextColor3 = Color3.fromRGB(180, 210, 255)
	questLevelLabel.Text = "Niveau 1"
	for i = 1, 3 do
		questLines[i] = makeLabel(quests, UDim2.fromOffset(8, 54 + (i - 1) * 30), UDim2.fromOffset(344, 26), false)
		questLines[i].TextScaled = false
		questLines[i].TextSize = 16
	end

	-- Panneau « Titres » (gauche, sous les quêtes, Lobby/Starting) : choix manuel.
	local titles = Instance.new("Frame")
	titles.Name = "Titles"
	titles.Size = UDim2.fromOffset(360, 168)
	titles.Position = UDim2.fromOffset(12, 284)
	titles.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	titles.BackgroundTransparency = 0.45
	titles.Visible = false
	titles.Parent = gui
	titlesPanel = titles

	local titlesTitle = makeLabel(titles, UDim2.fromOffset(8, 4), UDim2.fromOffset(260, 26), true)
	titlesTitle.Text = "Titres"
	titlesTitle.TextColor3 = Color3.fromRGB(255, 235, 160)

	-- Flash de confirmation (à droite du titre du panneau).
	titleFlashLabel = makeLabel(titles, UDim2.fromOffset(200, 6), UDim2.fromOffset(152, 22), false)
	titleFlashLabel.TextSize = 15
	titleFlashLabel.TextXAlignment = Enum.TextXAlignment.Right
	titleFlashLabel.TextColor3 = Color3.fromRGB(120, 230, 120)
	titleFlashLabel.Visible = false

	-- Liste défilante des titres possédés (boutons reconstruits à chaque QuestState).
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "TitleList"
	scroll.Size = UDim2.fromOffset(344, 128)
	scroll.Position = UDim2.fromOffset(8, 34)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.Parent = titles
	titlesScroll = scroll

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	-- Écran XP de fin (BAS-centre) : tes gains perso, sous le leaderboard central.
	local xp = Instance.new("Frame")
	xp.Name = "XpResult"
	xp.Size = UDim2.fromOffset(460, 218)
	xp.Position = UDim2.new(0.5, -230, 0.62, 0)
	xp.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	xp.BackgroundTransparency = 0.4
	xp.Visible = false
	xp.Parent = gui
	xpPanel = xp

	xpGainedLabel = makeLabel(xp, UDim2.fromOffset(10, 6), UDim2.fromOffset(440, 36), true)
	xpGainedLabel.TextColor3 = Color3.fromRGB(255, 235, 160)
	xpTitleLabel = makeLabel(xp, UDim2.fromOffset(10, 44), UDim2.fromOffset(440, 24), false)
	xpTitleLabel.TextSize = 17
	xpTitleLabel.Visible = false
	xpLevelLabel = makeLabel(xp, UDim2.fromOffset(10, 70), UDim2.fromOffset(440, 24), false)
	xpLevelLabel.TextSize = 18
	xpBreakdownLabel = makeLabel(xp, UDim2.fromOffset(10, 96), UDim2.fromOffset(440, 20), false)
	xpBreakdownLabel.TextSize = 14
	xpStatsLabel = makeLabel(xp, UDim2.fromOffset(10, 118), UDim2.fromOffset(440, 20), false)
	xpStatsLabel.TextSize = 14
	xpStatsLabel.TextColor3 = Color3.fromRGB(200, 220, 200)
	xpFriendLabel = makeLabel(xp, UDim2.fromOffset(10, 140), UDim2.fromOffset(440, 20), false)
	xpFriendLabel.TextSize = 15
	xpFriendLabel.TextColor3 = Color3.fromRGB(150, 210, 255)

	local invite = Instance.new("TextButton")
	invite.Name = "Invite"
	invite.Size = UDim2.fromOffset(440, 40)
	invite.Position = UDim2.fromOffset(10, 168)
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

	-- Leaderboard de fin (CENTRE) : panneau principal, sous la bannière vainqueur.
	local board = Instance.new("Frame")
	board.Name = "Leaderboard"
	board.Size = UDim2.fromOffset(560, 36 + LB_MAX_ROWS * 30 + 8)
	board.Position = UDim2.new(0.5, -280, 0.20, 0)
	board.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	board.BackgroundTransparency = 0.4
	board.Visible = false
	board.Parent = gui
	leaderboardPanel = board

	local boardTitle = makeLabel(board, UDim2.fromOffset(10, 4), UDim2.fromOffset(540, 26), false)
	boardTitle.Text = "Classement de la manche"
	boardTitle.TextSize = 18
	boardTitle.TextColor3 = Color3.fromRGB(255, 235, 160)

	for i = 1, LB_MAX_ROWS do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.Size = UDim2.fromOffset(540, 28)
		row.Position = UDim2.fromOffset(10, 36 + (i - 1) * 30)
		row.BackgroundColor3 = Color3.fromRGB(40, 90, 50)
		row.BackgroundTransparency = 1
		row.BorderSizePixel = 0
		row.Visible = false
		row.Parent = board

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = Color3.fromRGB(150, 210, 255)
		stroke.Transparency = 1 -- masqué par défaut (révélé pour le joueur local)
		stroke.Parent = row

		local lbl = makeLabel(row, UDim2.fromOffset(6, 0), UDim2.fromOffset(528, 28), false)
		lbl.TextSize = 14
		lbRows[i] = { frame = row, label = lbl, stroke = stroke }
	end

	screenGui = gui

	Remotes.RoundState.OnClientEvent:Connect(onRoundState)
	Remotes.QuestState.OnClientEvent:Connect(onQuestState)
	Remotes.XpResult.OnClientEvent:Connect(onXpResult)
	Remotes.RoundLeaderboard.OnClientEvent:Connect(onRoundLeaderboard)
end

return ProgressionController
