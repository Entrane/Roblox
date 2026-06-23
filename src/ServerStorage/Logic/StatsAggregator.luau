--!strict
-- StatsAggregator — Agrégation PURE des statistiques à vie d'un joueur.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR, comme RateLimiter/PlayerState : aucune dépendance Roblox, aucun
-- effet de bord. Toutes les fonctions prennent des records et en RENVOIENT de
-- nouveaux (jamais de mutation en place) → déterministes, shim-testables.
--
-- Sépare la LOGIQUE de comptage (ici) de la PERSISTANCE/affichage (DataStore +
-- leaderstats, dans ProgressionService, non testables hors Studio). Le type
-- `LifetimeStats` n'est PAS un contrat réseau (pas dans Types) : il ne sort pas
-- du serveur pour l'instant (DataStore + leaderstats uniquement).
--
-- ─── CHAMPS ─────────────────────────────────────────────────────────────
--   gamesPlayed  — parties jouées (total, pas journalier)
--   survivorWins — victoires en Survivant (= s'être échappé)
--   echoWins     — victoires en Écho (incarné ET faction Écho gagnante)
--   kills        — kills cumulés (Écho)
--   deaths       — morts cumulées (lifeState Dead ; PAS Escaped/Downed)
-- Le K/D n'est JAMAIS stocké : dérivé à la volée par kdRatio (évite toute
-- incohérence entre un ratio figé et ses composantes).

local StatsAggregator = {}

export type LifetimeStats = {
	gamesPlayed: number,
	survivorWins: number,
	echoWins: number,
	kills: number,
	deaths: number,
}

-- Issue d'UNE manche pour UN joueur (tout est déjà calculé par le Service).
export type RoundOutcome = {
	escaped: boolean, -- ce joueur s'est échappé (victoire survivant individuelle)
	isEcho: boolean, -- ce joueur était l'Écho
	echoWon: boolean, -- la faction Écho a gagné la manche
	kills: number, -- kills réalisés cette manche (0 si non-Écho)
	died: boolean, -- ce joueur a fini Dead
}

-- ───────────────────────────────────────────────────────────────────────
-- Helpers défensifs
-- ───────────────────────────────────────────────────────────────────────

-- Entier >= 0, sinon 0 : couvre nil / NaN / inf / négatif / non-nombre. Les
-- compteurs étant des entiers positifs, on plancher (floor) toute fraction.
local function counter(value: unknown): number
	if type(value) == "number" and value == value and value >= 0 and value ~= math.huge then
		return math.floor(value)
	end
	return 0
end

-- ───────────────────────────────────────────────────────────────────────
-- Constructeur / sanitation
-- ───────────────────────────────────────────────────────────────────────

-- Record vierge (défaut d'un nouveau joueur ou record DataStore absent).
function StatsAggregator.zero(): LifetimeStats
	return { gamesPlayed = 0, survivorWins = 0, echoWins = 0, kills = 0, deaths = 0 }
end

-- Coerce un record brut (issu du DataStore, potentiellement legacy/corrompu) en
-- LifetimeStats valide. Champs manquants/invalides → 0.
function StatsAggregator.sanitize(raw: unknown): LifetimeStats
	if type(raw) ~= "table" then
		return StatsAggregator.zero()
	end
	local t = raw :: { [string]: unknown }
	return {
		gamesPlayed = counter(t.gamesPlayed),
		survivorWins = counter(t.survivorWins),
		echoWins = counter(t.echoWins),
		kills = counter(t.kills),
		deaths = counter(t.deaths),
	}
end

-- ───────────────────────────────────────────────────────────────────────
-- Agrégation
-- ───────────────────────────────────────────────────────────────────────

-- Applique l'issue d'une manche à un record et RENVOIE un nouveau record. Base
-- et issue sont sanitées défensivement (un appelant fautif ne corrompt rien).
function StatsAggregator.apply(stats: LifetimeStats, outcome: RoundOutcome): LifetimeStats
	local s = StatsAggregator.sanitize(stats)
	local o = outcome
	local roundKills = if type(o) == "table" then counter(o.kills) else 0
	return {
		gamesPlayed = s.gamesPlayed + 1, -- chaque joueur présent compte une partie
		survivorWins = s.survivorWins + (if o.escaped then 1 else 0),
		echoWins = s.echoWins + (if (o.isEcho and o.echoWon) then 1 else 0),
		kills = s.kills + roundKills,
		deaths = s.deaths + (if o.died then 1 else 0),
	}
end

-- K/D dérivé. Convention : 0 mort → on renvoie `kills` (équivaut à kills/1),
-- évite la division par zéro tout en restant lisible (« 3 kills, 0 mort » → 3).
function StatsAggregator.kdRatio(stats: LifetimeStats): number
	local s = StatsAggregator.sanitize(stats)
	if s.deaths > 0 then
		return s.kills / s.deaths
	end
	return s.kills
end

-- Fusion anti-régression pour UpdateAsync : max champ par champ entre le record
-- en base (`old`, écrit par une autre session éventuelle) et le cache courant.
-- Cohérent avec le max(totalXp) de l'XP : un compteur monotone ne recule jamais.
function StatsAggregator.merge(old: unknown, cache: LifetimeStats): LifetimeStats
	local a = StatsAggregator.sanitize(old)
	local b = StatsAggregator.sanitize(cache)
	return {
		gamesPlayed = math.max(a.gamesPlayed, b.gamesPlayed),
		survivorWins = math.max(a.survivorWins, b.survivorWins),
		echoWins = math.max(a.echoWins, b.echoWins),
		kills = math.max(a.kills, b.kills),
		deaths = math.max(a.deaths, b.deaths),
	}
end

return StatsAggregator
