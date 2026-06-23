--!strict
-- TitleManager — Logique PURE des titres cosmétiques : paliers débloqués, union
-- sans doublon, sélection du titre par défaut, possession.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR, comme StatsAggregator/RateLimiter/LeaderboardBuilder : aucune
-- dépendance Roblox, aucune config interne. La table des paliers (MILESTONES)
-- reste dans ProgressionService et est PASSÉE en paramètre → module agnostique,
-- déterministe, shim-testable. ProgressionService n'est qu'un appelant.
--
-- L'ordre de `milestones` (croissant par niveau) est supposé par
-- getMilestoneRewards et lastUnlockedTitle (l'appelant garantit cet ordre).

local TitleManager = {}

export type Milestone = { level: number, rewardType: string, rewardValue: string }

-- Titres (rewardValue) débloqués en passant STRICTEMENT de oldLevel à newLevel
-- (oldLevel < palier <= newLevel). Vide si aucun palier franchi.
function TitleManager.getMilestoneRewards(milestones: { Milestone }, oldLevel: number, newLevel: number): { string }
	local rewards: { string } = {}
	for _, m in milestones do
		if m.rewardType == "title" and m.level > oldLevel and m.level <= newLevel then
			table.insert(rewards, m.rewardValue)
		end
	end
	return rewards
end

-- Fusionne `additions` dans `titles` SANS doublon (mutation en place, ordre
-- d'arrivée préservé). Sert au backfill de migration et à l'union anti-perte.
function TitleManager.mergeTitles(titles: { string }, additions: { string })
	local seen: { [string]: boolean } = {}
	for _, t in titles do
		seen[t] = true
	end
	for _, t in additions do
		if not seen[t] then
			seen[t] = true
			table.insert(titles, t)
		end
	end
end

-- Titre par défaut (MVP) = le DERNIER débloqué = le palier le plus élevé possédé.
-- Parcours croissant des paliers, on retient le dernier titre possédé. nil si
-- aucun (ne devrait pas arriver : niveau 1 = palier).
function TitleManager.lastUnlockedTitle(milestones: { Milestone }, titles: { string }): string?
	local owned: { [string]: boolean } = {}
	for _, t in titles do
		owned[t] = true
	end
	local result: string? = nil
	for _, m in milestones do
		if m.rewardType == "title" and owned[m.rewardValue] then
			result = m.rewardValue
		end
	end
	return result
end

-- `title` est-il dans la liste possédée ? Défensif : title non-chaîne → false.
-- Cœur de la validation serveur de SetActiveTitle (anti-triche : on n'équipe
-- jamais un titre non débloqué).
function TitleManager.isOwned(titles: { string }, title: unknown): boolean
	if type(title) ~= "string" then
		return false
	end
	return table.find(titles, title) ~= nil
end

return TitleManager
