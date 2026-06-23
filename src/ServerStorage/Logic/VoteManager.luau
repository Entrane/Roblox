--!strict
-- VoteManager — Décompte PUR des votes « rejouer » (écourter l'intermission).
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR (comme RateLimiter/StatsAggregator) : aucune dépendance Roblox,
-- aucun effet de bord. RoundService l'instancie, enregistre/retire les votes, et
-- interroge getResult pour décider d'écourter l'intermission. Aucune notion de
-- phase/réseau ici : juste un ensemble de userId + un seuil.
--
-- Les votes sont un ENSEMBLE (idempotent) : voter deux fois = un seul vote. Le
-- Service vide l'ensemble à chaque entrée en Resolved (nouveau scrutin).

local VoteManager = {}
VoteManager.__index = VoteManager

export type VoteManager = typeof(setmetatable(
	{} :: {
		votes: { [number]: boolean }, -- ensemble des userId ayant voté
	},
	VoteManager
))

function VoteManager.new(): VoteManager
	local self = setmetatable({}, VoteManager) :: VoteManager
	self.votes = {}
	return self
end

-- Enregistre un vote (idempotent). userId invalide → ignoré.
function VoteManager.addVote(self: VoteManager, userId: number)
	if type(userId) == "number" then
		self.votes[userId] = true
	end
end

-- Retire un vote (ex. le votant quitte). Idempotent.
function VoteManager.removeVote(self: VoteManager, userId: number)
	if type(userId) == "number" then
		self.votes[userId] = nil
	end
end

-- Nouveau scrutin (entrée en Resolved).
function VoteManager.clear(self: VoteManager)
	self.votes = {}
end

function VoteManager.count(self: VoteManager): number
	local n = 0
	for _ in self.votes do
		n += 1
	end
	return n
end

-- Vrai si la fraction de votants atteint le seuil : count / total >= threshold,
-- soit count >= total * threshold (threshold = 0.5 → « ≥ 50 % ont voté »).
-- Défensif : total ≤ 0 ou seuil non-nombre → false.
function VoteManager.getResult(self: VoteManager, total: number, threshold: number): boolean
	if type(total) ~= "number" or total <= 0 or type(threshold) ~= "number" then
		return false
	end
	return self:count() >= total * threshold
end

return VoteManager
