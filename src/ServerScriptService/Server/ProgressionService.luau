--!strict
-- ProgressionService — XP / niveaux persistés + quêtes journalières + bonus amis.
-- À la fin de manche (Playing→Resolved), calcule l'XP de chaque joueur d'après sa
-- performance (lue dans les compteurs de PlayerService/FuseService), applique le
-- bonus amis (IsFriendsWith, serveur), met à jour les quêtes du jour, persiste, et
-- pousse XpResult + QuestState au SEUL joueur concerné (FireClient).
--
-- ⚠️ NE TOUCHE AUCUN module Logic : ne lit que des Services. DataStore TOUJOURS en
-- pcall → jamais de crash si indisponible (Studio sans API access, panne…).
--
-- ─── DEUX DataStores INDÉPENDANTS (clé = userId) ────────────────────────
--   PlayerXP_v1     -> { totalXp }
--   DailyQuests_v1  -> { date, gamesPlayed, q1Done, q2Done, q3Done }
-- Caches mémoire distincts. Chargement au PlayerAdded, sauvegarde au Resolved, au
-- PlayerRemoving et au BindToClose. Stores/namespaces séparés → aucun conflit.
--
-- ─── RÉCOMPENSES PAR PALIER (titres) ────────────────────────────────────
-- Chaque palier de niveau (table MILESTONES) débloque un TITRE cosmétique,
-- persisté dans PlayerXP_v1 (unlockedTitles + activeTitle) et poussé au client
-- via XpResult (fin de manche) + QuestState (lobby). Le titre actif est, pour le
-- MVP, AUTO-sélectionné = dernier débloqué.
--
-- ⚠️ TODO : skins / cosmétiques 3D — la structure {level, rewardType, rewardValue}
-- est déjà prête à accueillir d'autres rewardType que "title" (ex. "skin"),
-- mais cela demande des assets et un canal d'équipement (hors MVP).
-- ⚠️ TODO : choix MANUEL du titre actif par le joueur (Remote SetActiveTitle +
-- validation « titre possédé »). Pour l'instant : auto = dernier débloqué.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StatsAggregator = require(ServerStorage.Logic.StatsAggregator)
local LeaderboardBuilder = require(ServerStorage.Logic.LeaderboardBuilder)
local TitleManager = require(ServerStorage.Logic.TitleManager)
local RateLimiter = require(ServerStorage.Logic.RateLimiter)
local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local RoundService = require(script.Parent.RoundService)
local PlayerService = require(script.Parent.PlayerService)
local FuseService = require(script.Parent.FuseService)
local EchoService = require(script.Parent.EchoService)

local ProgressionService = {}

-- ───────────────────────────────────────────────────────────────────────
-- Valeurs réglables (config SERVEUR, volontairement hors GameConfig)
-- ───────────────────────────────────────────────────────────────────────
local XP_PARTICIPATION = 50
local XP_ESCAPED = 100
local XP_FUSE = 20 -- par fusible déposé
local XP_REVIVE = 30 -- par réanimation réussie
local XP_KILL = 40 -- par kill (Écho)
local FRIEND_BONUS_PER = 0.25 -- +25 % par ami présent

local QUEST1_XP = 150 -- jouer 3 parties
local QUEST2_XP = 200 -- gagner en Écho
local QUEST3_XP = 200 -- gagner en Survivant (= s'être échappé)

local XP_PER_LEVEL = 500 -- courbe simple : niveau = floor(xp / 500) + 1

local XP_STORE = "PlayerXP_v1"
local QUEST_STORE = "DailyQuests_v1"

-- Paliers de récompense. rewardType = "title" uniquement pour le MVP (cf. TODO
-- skins en tête de fichier). Triés par niveau croissant : TitleManager
-- (getMilestoneRewards/lastUnlockedTitle) s'appuie sur cet ordre. La table reste
-- ICI (config) ; TitleManager la reçoit en paramètre (module pur agnostique).
local MILESTONES: { TitleManager.Milestone } = {
	{ level = 1, rewardType = "title", rewardValue = "Nouveau Venu" },
	{ level = 3, rewardType = "title", rewardValue = "Recrue du Bunker" },
	{ level = 5, rewardType = "title", rewardValue = "Survivant Endurci" },
	{ level = 8, rewardType = "title", rewardValue = "Veilleur de Nuit" },
	{ level = 10, rewardType = "title", rewardValue = "Chasseur de l'Ombre" },
	{ level = 15, rewardType = "title", rewardValue = "Briseur de Silence" },
	{ level = 20, rewardType = "title", rewardValue = "Rescapé du Signal" },
	{ level = 25, rewardType = "title", rewardValue = "Fantôme du Bunker" },
	{ level = 30, rewardType = "title", rewardValue = "Spectre du Signal" },
	{ level = 40, rewardType = "title", rewardValue = "Légende de Signal Lost" },
}

-- ───────────────────────────────────────────────────────────────────────
-- État de module
-- ───────────────────────────────────────────────────────────────────────

-- Record « profil » persisté dans PlayerXP_v1 : XP + titres + stats à vie. Les
-- stats sont bundlées ici (et pas dans un store séparé) car elles changent au
-- MÊME instant que l'XP (au Resolved) → un seul UpdateAsync (budget DataStore).
type XpData = { totalXp: number, unlockedTitles: { string }, activeTitle: string?, stats: StatsAggregator.LifetimeStats }
type QuestData = { date: string, gamesPlayed: number, q1Done: boolean, q2Done: boolean, q3Done: boolean }

-- ⚠️ Init DataStore en pcall : en Studio local sans accès API aux services
-- (« You must publish this place to use DataStore »), GetDataStore peut LEVER.
-- Comme c'est au top-niveau du module, ça ferait échouer le require → tout
-- init.server (donc le serveur entier) ne démarrerait pas. On dégrade
-- gracieusement : warn + caches MÉMOIRE seuls (aucune persistance cette session).
local xpStore: DataStore? = nil
local questStore: DataStore? = nil
do
	local ok, err = pcall(function()
		xpStore = DataStoreService:GetDataStore(XP_STORE)
		questStore = DataStoreService:GetDataStore(QUEST_STORE)
	end)
	if not ok then
		xpStore = nil
		questStore = nil
		warn(
			"[ProgressionService] DataStore indisponible ("
				.. tostring(err)
				.. ") : progression EN MÉMOIRE seulement (aucune persistance)."
		)
	end
end

local xpCache: { [number]: XpData } = {}
local questCache: { [number]: QuestData } = {}

-- Anti-spam DataStore : 1 save max / 30 s / joueur (sauf force = départ/shutdown).
local SAVE_COOLDOWN = 30 -- s
local lastSaveAt: { [number]: number } = {} -- userId -> os.clock du dernier save

local lastPhase: Types.RoundPhase = RoundService.getRoundManager():getPhase()
local initialized = false

-- Anti-flood de SetActiveTitle (cohérence #6 : garde token bucket par joueur).
local rateLimiter: RateLimiter.RateLimiter = RateLimiter.new()
local IS_STUDIO = RunService:IsStudio()

-- ───────────────────────────────────────────────────────────────────────
-- Helpers
-- ───────────────────────────────────────────────────────────────────────

local function todayUTC(): string
	return os.date("!%Y-%m-%d") :: string
end

local function levelFromXp(xp: number): number
	return math.floor(xp / XP_PER_LEVEL) + 1
end

-- mergeTitles / lastUnlockedTitle / getMilestoneRewards vivent désormais dans
-- TitleManager (Logic pur, shim-testé) ; on les appelle avec MILESTONES.

local function defaultQuests(): QuestData
	return { date = todayUTC(), gamesPlayed = 0, q1Done = false, q2Done = false, q3Done = false }
end

-- Reset journalier si la date stockée n'est plus celle du jour (UTC).
local function ensureToday(q: QuestData)
	if q.date ~= todayUTC() then
		q.date = todayUTC()
		q.gamesPlayed = 0
		q.q1Done = false
		q.q2Done = false
		q.q3Done = false
	end
end

local function buildQuestState(uid: number): Types.QuestState
	local q = questCache[uid] or defaultQuests()
	local xp = xpCache[uid]
	return {
		quests = {
			{ id = "q1", label = "Jouer 3 parties", progress = math.min(q.gamesPlayed, 3), goal = 3, complete = q.q1Done, xpReward = QUEST1_XP },
			{ id = "q2", label = "Gagner en tant qu'Écho", progress = if q.q2Done then 1 else 0, goal = 1, complete = q.q2Done, xpReward = QUEST2_XP },
			{ id = "q3", label = "Gagner en tant que Survivant", progress = if q.q3Done then 1 else 0, goal = 1, complete = q.q3Done, xpReward = QUEST3_XP },
		},
		level = if xp then levelFromXp(xp.totalXp) else 1,
		activeTitle = if xp then xp.activeTitle else nil,
		unlockedTitles = if xp then xp.unlockedTitles else {},
	}
end

local function sendQuestState(player: Player, uid: number)
	Remotes.QuestState:FireClient(player, buildQuestState(uid))
end

-- ───────────────────────────────────────────────────────────────────────
-- DataStore (toujours en pcall)
-- ───────────────────────────────────────────────────────────────────────

-- leaderstats natifs (Tab) : Niveau, Victoires, K/D. Créés une fois le profil
-- chargé, rafraîchis après chaque manche. Parentés au Player → auto-détruits au
-- départ (aucun nettoyage manuel). API Roblox pure : la logique de VALEURS vit
-- dans StatsAggregator (testée) ; ici on ne fait que peupler des *Value.
local function updateLeaderstats(player: Player, uid: number)
	local cache = xpCache[uid]
	if not cache then
		return
	end
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		local level = Instance.new("IntValue")
		level.Name = "Niveau"
		level.Parent = folder
		local wins = Instance.new("IntValue")
		wins.Name = "Victoires"
		wins.Parent = folder
		local kd = Instance.new("NumberValue")
		kd.Name = "K/D"
		kd.Parent = folder
		folder.Parent = player
	end
	-- Cast au FindFirstChild (et non sur la ligne d'affectation) : évite le « (… ) »
	-- en tête d'instruction (syntaxe ambiguë Luau) et garde des accès typés.
	local levelV = folder:FindFirstChild("Niveau") :: IntValue?
	local winsV = folder:FindFirstChild("Victoires") :: IntValue?
	local kdV = folder:FindFirstChild("K/D") :: NumberValue?
	if levelV then
		levelV.Value = levelFromXp(cache.totalXp)
	end
	if winsV then
		winsV.Value = cache.stats.survivorWins + cache.stats.echoWins
	end
	if kdV then
		-- Arrondi 2 décimales pour un affichage Tab lisible.
		local r = StatsAggregator.kdRatio(cache.stats)
		kdV.Value = math.floor(r * 100 + 0.5) / 100
	end
end

local function loadPlayer(player: Player)
	local uid = player.UserId
	local key = tostring(uid)

	-- DataStore absent (Studio sans API) → lecture sautée, valeurs par défaut.
	local ok, data = false, nil
	if xpStore then
		ok, data = pcall(function()
			return xpStore:GetAsync(key)
		end)
	end
	local totalXp = 0
	local titles: { string } = {}
	local activeTitle: string? = nil
	if ok and type(data) == "table" then
		totalXp = tonumber(data.totalXp) or 0
		-- Sanitation : on ne garde que des chaînes (record legacy ou corrompu).
		if type(data.unlockedTitles) == "table" then
			for _, t in data.unlockedTitles do
				if type(t) == "string" then
					table.insert(titles, t)
				end
			end
		end
		if type(data.activeTitle) == "string" then
			activeTitle = data.activeTitle
		end
	elseif xpStore and not ok then
		warn("[ProgressionService] GetAsync XP échoué pour " .. key .. " : valeurs par défaut.")
	end
	-- Migration / cohérence : un compte (legacy ou non) doit posséder TOUS les
	-- titres mérités par son niveau actuel, même si le champ n'existait pas.
	TitleManager.mergeTitles(titles, TitleManager.getMilestoneRewards(MILESTONES, 0, levelFromXp(totalXp)))
	-- Auto-sélection MVP du titre actif s'il manque ou n'est plus possédé.
	if activeTitle == nil or not TitleManager.isOwned(titles, activeTitle) then
		activeTitle = TitleManager.lastUnlockedTitle(MILESTONES, titles)
	end
	-- Stats à vie : sanitées (record legacy sans `stats` → tout à zéro).
	local lifeStats = StatsAggregator.sanitize(if ok and type(data) == "table" then data.stats else nil)
	xpCache[uid] = { totalXp = totalXp, unlockedTitles = titles, activeTitle = activeTitle, stats = lifeStats }

	local ok2, qdata = false, nil
	if questStore then
		ok2, qdata = pcall(function()
			return questStore:GetAsync(key)
		end)
	end
	local q: QuestData
	if ok2 and type(qdata) == "table" then
		q = {
			date = tostring(qdata.date),
			gamesPlayed = tonumber(qdata.gamesPlayed) or 0,
			q1Done = qdata.q1Done == true,
			q2Done = qdata.q2Done == true,
			q3Done = qdata.q3Done == true,
		}
	else
		q = defaultQuests()
		if questStore and not ok2 then
			warn("[ProgressionService] GetAsync quêtes échoué pour " .. key .. " : valeurs par défaut.")
		end
	end
	ensureToday(q) -- reset si le jour a changé depuis la dernière session
	questCache[uid] = q

	sendQuestState(player, uid) -- le client a son état de quêtes dès l'arrivée
	updateLeaderstats(player, uid) -- Tab peuplé dès l'arrivée (Niveau/Victoires/K/D)
end

-- force = true : sauvegarde TOUJOURS (PlayerRemoving / BindToClose, anti-perte).
-- Sinon : throttlé (anti-spam). La mémoire reste autoritaire → un save sauté est
-- rattrapé au prochain save non throttlé ou au départ.
local function savePlayer(uid: number, force: boolean?)
	if not force then
		local last = lastSaveAt[uid]
		if last and (os.clock() - last) < SAVE_COOLDOWN then
			return
		end
	end
	lastSaveAt[uid] = os.clock()

	local key = tostring(uid)
	local xp = xpCache[uid]
	local q = questCache[uid]

	if xp and xpStore then
		pcall(function()
			xpStore:UpdateAsync(key, function(old)
				-- max() : ne jamais régresser l'XP si une autre session avait écrit plus.
				local prev = (type(old) == "table" and tonumber(old.totalXp)) or 0
				-- Union des titres : on repart des titres déjà en base (autre session)
				-- et on y fusionne ceux du cache → aucun titre gagné n'est perdu.
				local merged: { string } = {}
				if type(old) == "table" and type(old.unlockedTitles) == "table" then
					for _, t in old.unlockedTitles do
						if type(t) == "string" then
							table.insert(merged, t)
						end
					end
				end
				TitleManager.mergeTitles(merged, xp.unlockedTitles)
				-- Stats : max champ par champ (anti-régression, comme totalXp).
				local mergedStats = StatsAggregator.merge(if type(old) == "table" then old.stats else nil, xp.stats)
				return { totalXp = math.max(prev, xp.totalXp), unlockedTitles = merged, activeTitle = xp.activeTitle, stats = mergedStats }
			end)
		end)
	end

	if q and questStore then
		pcall(function()
			questStore:UpdateAsync(key, function(_old)
				return { date = q.date, gamesPlayed = q.gamesPlayed, q1Done = q.q1Done, q2Done = q.q2Done, q3Done = q.q3Done }
			end)
		end)
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Quêtes : mise à jour à la fin de manche. Renvoie l'XP de récompense gagné
-- CETTE manche (sera additionné au total par l'appelant via xpGained).
-- ───────────────────────────────────────────────────────────────────────

local function updateQuests(uid: number, isEcho: boolean, winner: Types.Faction?, escaped: boolean): number
	local q = questCache[uid]
	if not q then
		return 0
	end
	ensureToday(q)

	local reward = 0
	q.gamesPlayed += 1
	if not q.q1Done and q.gamesPlayed >= 3 then
		q.q1Done = true
		reward += QUEST1_XP
	end
	if not q.q2Done and isEcho and winner == Types.Faction.Echo then
		q.q2Done = true
		reward += QUEST2_XP
	end
	if not q.q3Done and escaped then
		q.q3Done = true
		reward += QUEST3_XP
	end
	return reward
end

-- ───────────────────────────────────────────────────────────────────────
-- Bonus amis (serveur, autoritaire) — IsFriendsWith pairwise, pcall
-- ───────────────────────────────────────────────────────────────────────

type Snap = {
	player: Player,
	uid: number,
	name: string, -- DisplayName capturé en SYNCHRONE (robuste à un départ pendant les yields)
	matchXp: number,
	escaped: boolean,
	isEcho: boolean,
	died: boolean, -- a fini Dead (pour la stat à vie ; pas Escaped/Downed)
	breakdown: Types.XpBreakdown,
	roundStats: Types.RoundStats,
}

local function countFriends(player: Player, snaps: { Snap }): number
	local count = 0
	for _, other in snaps do
		if other.uid ~= player.UserId then
			local ok, isFriend = pcall(function()
				return player:IsFriendsWith(other.uid)
			end)
			if ok and isFriend then
				count += 1
			end
		end
	end
	return count
end

-- ───────────────────────────────────────────────────────────────────────
-- Fin de manche : snapshot SYNCHRONE puis award ASYNCHRONE (yields isolés)
-- ───────────────────────────────────────────────────────────────────────

local function onResolved()
	local winner = RoundService.getRoundManager():getState().winner
	local echoId = EchoService.getRoleManager():getEchoUserId()
	local playerState = PlayerService.getPlayerState()
	local stats = PlayerService.getRoundStats()
	local deposits = FuseService.getRoundDeposits()
	local players = Players:GetPlayers()
	local playerCount = #players

	-- Snapshot synchrone (avant tout yield) : composants d'XP par participant.
	local snaps: { Snap } = {}
	for _, player in players do
		local uid = player.UserId
		local lifeSnap = playerState:getState(uid)
		local escaped = lifeSnap ~= nil and lifeSnap.lifeState == Types.LifeState.Escaped
		local died = lifeSnap ~= nil and lifeSnap.lifeState == Types.LifeState.Dead
		local isEcho = echoId ~= nil and uid == echoId

		local nDeposits = deposits[uid] or 0
		local nRevives = stats.revives[uid] or 0
		local nKills = if isEcho then stats.kills else 0

		local xpEscaped = if escaped then XP_ESCAPED else 0
		local xpDeposits = nDeposits * XP_FUSE
		local xpRevives = nRevives * XP_REVIVE
		local xpKills = nKills * XP_KILL
		local matchXp = XP_PARTICIPATION + xpEscaped + xpDeposits + xpRevives + xpKills

		table.insert(snaps, {
			player = player,
			uid = uid,
			name = player.DisplayName,
			matchXp = matchXp,
			escaped = escaped,
			isEcho = isEcho,
			died = died,
			breakdown = {
				participation = XP_PARTICIPATION,
				escaped = xpEscaped,
				deposits = xpDeposits,
				revives = xpRevives,
				kills = xpKills,
				quests = 0, -- complété ci-dessous
			},
			roundStats = {
				deposits = nDeposits,
				revives = nRevives,
				kills = nKills,
				survivalSeconds = stats.survival[uid] or 0,
			},
		})
	end

	-- Award asynchrone : IsFriendsWith + DataStore yield → hors du tick.
	task.spawn(function()
		-- Entrées du leaderboard collectées au fil de la boucle (xpGained final
		-- connu seulement après calcul) ; triées + diffusées APRÈS la boucle.
		local entries: { Types.LeaderboardEntry } = {}
		for _, s in snaps do
			local cache = xpCache[s.uid]
			if cache then
				local friendCount = countFriends(s.player, snaps)
				local bonus = math.floor(s.matchXp * FRIEND_BONUS_PER * friendCount)
				local questReward = updateQuests(s.uid, s.isEcho, winner, s.escaped)
				local gained = s.matchXp + bonus + questReward

				-- Détection de palier : niveau AVANT vs APRÈS le gain de cette manche.
				local oldLevel = levelFromXp(cache.totalXp)
				cache.totalXp += gained
				local newLevel = levelFromXp(cache.totalXp)
				s.breakdown.quests = questReward

				local newTitles = TitleManager.getMilestoneRewards(MILESTONES, oldLevel, newLevel)
				if #newTitles > 0 then
					TitleManager.mergeTitles(cache.unlockedTitles, newTitles)
					-- Auto-sélection MVP : le plus haut palier franchi (dernier de la liste).
					cache.activeTitle = newTitles[#newTitles]
				end

				-- Stats à vie : applique l'issue de la manche (avant le save, qui les persiste).
				cache.stats = StatsAggregator.apply(cache.stats, {
					escaped = s.escaped,
					isEcho = s.isEcho,
					echoWon = winner == Types.Faction.Echo,
					kills = s.roundStats.kills,
					died = s.died,
				})

				Remotes.XpResult:FireClient(s.player, {
					xp = cache.totalXp,
					level = newLevel,
					xpGained = gained,
					breakdown = s.breakdown,
					stats = s.roundStats,
					activeTitle = cache.activeTitle,
					newTitles = newTitles,
					friendBonus = bonus,
					friendCount = friendCount,
					suggestInvite = playerCount < 4,
					playerCount = playerCount,
				})
				sendQuestState(s.player, s.uid)
				savePlayer(s.uid)
				updateLeaderstats(s.player, s.uid) -- Tab rafraîchi (Niveau/Victoires/K/D)

				-- Ligne de leaderboard (won = faction gagnante).
				local won = (s.isEcho and winner == Types.Faction.Echo)
					or (not s.isEcho and winner == Types.Faction.Survivors)
				table.insert(entries, {
					userId = s.uid,
					name = s.name,
					isEcho = s.isEcho,
					won = won,
					xpGained = gained,
					kills = s.roundStats.kills,
					deposits = s.roundStats.deposits,
					revives = s.roundStats.revives,
					survivalSeconds = s.roundStats.survivalSeconds,
				})
			end
		end

		-- Diffusion UNIQUE du classement trié à TOUS (données non secrètes).
		Remotes.RoundLeaderboard:FireAllClients({
			winner = winner,
			entries = LeaderboardBuilder.build(entries),
		})
	end)
end

-- ───────────────────────────────────────────────────────────────────────
-- Choix manuel du titre actif (client → serveur, AUTORITÉ SERVEUR)
-- ───────────────────────────────────────────────────────────────────────

-- Identité = player (OnServerEvent). Anti-flood (rate limit) + validation
-- « titre POSSÉDÉ » (TitleManager.isOwned) : on n'équipe jamais un titre non
-- débloqué (le client n'affiche que les possédés → rejet = exploit). Sur succès :
-- persiste + renvoie QuestState (confirmation autoritaire, le client met à jour l'UI).
local function onSetActiveTitle(player: Player, title: any)
	local uid = player.UserId
	local allowed, firstRejection = rateLimiter:allow(uid, "SetActiveTitle", 4, 2, os.clock())
	if not allowed then
		if IS_STUDIO and firstRejection then
			warn(string.format("[ProgressionService] Rate limit : SetActiveTitle rejeté (rafale) pour le joueur %d.", uid))
		end
		return
	end
	local cache = xpCache[uid]
	if not cache then
		return
	end
	if not TitleManager.isOwned(cache.unlockedTitles, title) then
		return -- titre non possédé / charge invalide : ignoré
	end
	cache.activeTitle = title :: string
	savePlayer(uid)
	sendQuestState(player, uid) -- confirmation autoritaire (UI client resynchronisée)
end

-- ───────────────────────────────────────────────────────────────────────
-- Tick : détecte l'entrée en Resolved
-- ───────────────────────────────────────────────────────────────────────

local function tick()
	local phase = RoundService.getRoundManager():getPhase()
	if phase ~= lastPhase then
		if phase == Types.RoundPhase.Resolved and lastPhase == Types.RoundPhase.Playing then
			onResolved()
		end
		lastPhase = phase
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Interface publique
-- ───────────────────────────────────────────────────────────────────────

function ProgressionService.init()
	if initialized then
		return
	end
	initialized = true

	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPlayer, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		local uid = player.UserId
		savePlayer(uid, true) -- TOUJOURS au départ (anti-perte, ignore le throttle)
		xpCache[uid] = nil
		questCache[uid] = nil
		lastSaveAt[uid] = nil
		rateLimiter:removePlayer(uid) -- libère le seau anti-flood du joueur
	end)

	Remotes.SetActiveTitle.OnServerEvent:Connect(onSetActiveTitle)

	-- Sauvegarde de tous les joueurs à l'arrêt du serveur (anti-perte, forcée).
	game:BindToClose(function()
		for uid in xpCache do
			savePlayer(uid, true)
		end
	end)

	RunService.Heartbeat:Connect(tick)
end

return ProgressionService
