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
-- ⚠️ TODO RÉCOMPENSES PAR PALIER (à designer) : aujourd'hui le NIVEAU est purement
-- indicatif (aucune récompense matérielle). À définir plus tard : que donner à
-- chaque palier (cosmétiques ? skins d'Écho ? variantes de capacités ?), et le
-- canal d'attribution (probablement ici, à la montée de niveau détectée au award).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

-- ───────────────────────────────────────────────────────────────────────
-- État de module
-- ───────────────────────────────────────────────────────────────────────

type XpData = { totalXp: number }
type QuestData = { date: string, gamesPlayed: number, q1Done: boolean, q2Done: boolean, q3Done: boolean }

local xpStore = DataStoreService:GetDataStore(XP_STORE)
local questStore = DataStoreService:GetDataStore(QUEST_STORE)

local xpCache: { [number]: XpData } = {}
local questCache: { [number]: QuestData } = {}

-- Anti-spam DataStore : 1 save max / 30 s / joueur (sauf force = départ/shutdown).
local SAVE_COOLDOWN = 30 -- s
local lastSaveAt: { [number]: number } = {} -- userId -> os.clock du dernier save

local lastPhase: Types.RoundPhase = RoundService.getRoundManager():getPhase()
local initialized = false

-- ───────────────────────────────────────────────────────────────────────
-- Helpers
-- ───────────────────────────────────────────────────────────────────────

local function todayUTC(): string
	return os.date("!%Y-%m-%d") :: string
end

local function levelFromXp(xp: number): number
	return math.floor(xp / XP_PER_LEVEL) + 1
end

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
	return {
		quests = {
			{ id = "q1", label = "Jouer 3 parties", progress = math.min(q.gamesPlayed, 3), goal = 3, complete = q.q1Done, xpReward = QUEST1_XP },
			{ id = "q2", label = "Gagner en tant qu'Écho", progress = if q.q2Done then 1 else 0, goal = 1, complete = q.q2Done, xpReward = QUEST2_XP },
			{ id = "q3", label = "Gagner en tant que Survivant", progress = if q.q3Done then 1 else 0, goal = 1, complete = q.q3Done, xpReward = QUEST3_XP },
		},
	}
end

local function sendQuestState(player: Player, uid: number)
	Remotes.QuestState:FireClient(player, buildQuestState(uid))
end

-- ───────────────────────────────────────────────────────────────────────
-- DataStore (toujours en pcall)
-- ───────────────────────────────────────────────────────────────────────

local function loadPlayer(player: Player)
	local uid = player.UserId
	local key = tostring(uid)

	local ok, data = pcall(function()
		return xpStore:GetAsync(key)
	end)
	if ok and type(data) == "table" then
		xpCache[uid] = { totalXp = tonumber(data.totalXp) or 0 }
	else
		xpCache[uid] = { totalXp = 0 }
		if not ok then
			warn("[ProgressionService] GetAsync XP échoué pour " .. key .. " : valeurs par défaut.")
		end
	end

	local ok2, qdata = pcall(function()
		return questStore:GetAsync(key)
	end)
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
		if not ok2 then
			warn("[ProgressionService] GetAsync quêtes échoué pour " .. key .. " : valeurs par défaut.")
		end
	end
	ensureToday(q) -- reset si le jour a changé depuis la dernière session
	questCache[uid] = q

	sendQuestState(player, uid) -- le client a son état de quêtes dès l'arrivée
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

	if xp then
		pcall(function()
			xpStore:UpdateAsync(key, function(old)
				-- max() : ne jamais régresser l'XP si une autre session avait écrit plus.
				local prev = (type(old) == "table" and tonumber(old.totalXp)) or 0
				return { totalXp = math.max(prev, xp.totalXp) }
			end)
		end)
	end

	if q then
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
	matchXp: number,
	escaped: boolean,
	isEcho: boolean,
	breakdown: Types.XpBreakdown,
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
		local isEcho = echoId ~= nil and uid == echoId

		local xpEscaped = if escaped then XP_ESCAPED else 0
		local xpDeposits = (deposits[uid] or 0) * XP_FUSE
		local xpRevives = (stats.revives[uid] or 0) * XP_REVIVE
		local xpKills = if isEcho then stats.kills * XP_KILL else 0
		local matchXp = XP_PARTICIPATION + xpEscaped + xpDeposits + xpRevives + xpKills

		table.insert(snaps, {
			player = player,
			uid = uid,
			matchXp = matchXp,
			escaped = escaped,
			isEcho = isEcho,
			breakdown = {
				participation = XP_PARTICIPATION,
				escaped = xpEscaped,
				deposits = xpDeposits,
				revives = xpRevives,
				kills = xpKills,
				quests = 0, -- complété ci-dessous
			},
		})
	end

	-- Award asynchrone : IsFriendsWith + DataStore yield → hors du tick.
	task.spawn(function()
		for _, s in snaps do
			local cache = xpCache[s.uid]
			if cache then
				local friendCount = countFriends(s.player, snaps)
				local bonus = math.floor(s.matchXp * FRIEND_BONUS_PER * friendCount)
				local questReward = updateQuests(s.uid, s.isEcho, winner, s.escaped)
				local gained = s.matchXp + bonus + questReward

				cache.totalXp += gained
				s.breakdown.quests = questReward

				Remotes.XpResult:FireClient(s.player, {
					xp = cache.totalXp,
					level = levelFromXp(cache.totalXp),
					xpGained = gained,
					breakdown = s.breakdown,
					friendBonus = bonus,
					friendCount = friendCount,
					suggestInvite = playerCount < 4,
					playerCount = playerCount,
				})
				sendQuestState(s.player, s.uid)
				savePlayer(s.uid)
			end
		end
	end)
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
	end)

	-- Sauvegarde de tous les joueurs à l'arrêt du serveur (anti-perte, forcée).
	game:BindToClose(function()
		for uid in xpCache do
			savePlayer(uid, true)
		end
	end)

	RunService.Heartbeat:Connect(tick)
end

return ProgressionService
