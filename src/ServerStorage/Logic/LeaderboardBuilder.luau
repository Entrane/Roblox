--!strict
-- LeaderboardBuilder — Construction PURE du classement de fin de manche.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR, comme StatsAggregator/RateLimiter : aucune dépendance Roblox,
-- aucun effet de bord. `build` reçoit des entrées brutes (collectées par le
-- Service à partir des snaps) et RENVOIE une NOUVELLE liste triée → déterministe,
-- shim-testable. La LECTURE des snaps (Players, RoundStats…) reste dans le
-- Service (non testable) ; seul l'ORDRE est ici.
--
-- ─── TRI (déterministe) ─────────────────────────────────────────────────
-- xpGained décroissant → kills décroissant → userId croissant. Le 3e critère
-- garantit un ordre stable malgré l'itération non ordonnée des tables Lua (deux
-- joueurs à XP/kills égaux ne « dansent » jamais d'un appel à l'autre).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

local LeaderboardBuilder = {}

-- Comparateur total et déterministe (jamais d'égalité non tranchée : userId est
-- unique). table.sort exige un ordre strict cohérent — assuré ici.
local function compareEntries(a: Types.LeaderboardEntry, b: Types.LeaderboardEntry): boolean
	if a.xpGained ~= b.xpGained then
		return a.xpGained > b.xpGained
	end
	if a.kills ~= b.kills then
		return a.kills > b.kills
	end
	return a.userId < b.userId
end

-- Renvoie une COPIE triée des entrées (n'altère pas la liste reçue). Défensif :
-- entrée non-table → liste vide.
function LeaderboardBuilder.build(entries: { Types.LeaderboardEntry }): { Types.LeaderboardEntry }
	if type(entries) ~= "table" then
		return {}
	end
	local sorted: { Types.LeaderboardEntry } = table.clone(entries)
	table.sort(sorted, compareEntries)
	return sorted
end

return LeaderboardBuilder
