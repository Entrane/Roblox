--!strict
-- RateLimiter — Limiteur de débit générique (token bucket) pour les Remotes.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR, comme PlayerState/FuseSystem/RoundManager : aucune dépendance
-- Roblox (pas de game, pas d'Instance, pas de RunService, pas d'os.clock). Le
-- temps `now` est TOUJOURS fourni en paramètre par l'appelant (le Service passe
-- os.clock()). Conséquence : 100 % déterministe → shim-testable hors Studio.
--
-- Le module ne connaît AUCUN nom de Remote : il est générique. Chaque Service
-- déclare ses propres limites (capacité/recharge) au site de branchement. Il
-- n'émet rien (pas de warn) : la décision « warn en Studio sur la 1re rafale »
-- est prise par le Service à partir du 2e retour de :allow (cf. plus bas).
--
-- ─── ALGORITHME : token bucket à recharge PARESSEUSE ────────────────────
-- Un seau par couple (userId, name) : capacité C, recharge R jetons/s. Chaque
-- appel consomme 1 jeton ; plus de jeton → rejet. Le seau se recharge
-- mathématiquement À LA LECTURE (tokens = min(C, tokens + écoulé×R)) : aucune
-- boucle, coût nul quand le Remote n'est pas appelé. Autorise les RAFALES
-- légitimes (jusqu'à C d'un coup) tout en plafonnant le débit SOUTENU à R.
--
-- ─── DÉPENDANCES ────────────────────────────────────────────────────────
-- Aucune. Module autonome (pas même GameConfig/Types : les limites sont
-- passées par l'appelant, le seul « état » est numérique).

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- Seau interne (jamais exposé). `rejecting` mémorise qu'on est DANS une rafale
-- rejetée → sert à ne signaler QUE la première frappe rejetée d'une rafale.
type Bucket = {
	tokens: number,
	lastRefill: number,
	rejecting: boolean,
}

export type RateLimiter = typeof(setmetatable(
	{} :: {
		-- buckets[userId][name] = seau. Imbriqué par userId → nettoyage O(1) au départ.
		buckets: { [number]: { [string]: Bucket } },
	},
	RateLimiter
))

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

function RateLimiter.new(): RateLimiter
	local self = setmetatable({}, RateLimiter) :: RateLimiter
	self.buckets = {}
	return self
end

-- ───────────────────────────────────────────────────────────────────────
-- Helpers défensifs (coercition douce : un paramètre invalide ne plante pas)
-- ───────────────────────────────────────────────────────────────────────

-- Nombre fini > 0, sinon repli. Couvre nil/NaN/inf/≤0 (capacité/recharge folles).
local function positiveOr(value: unknown, fallback: number): number
	if type(value) == "number" and value == value and value > 0 and value ~= math.huge then
		return value
	end
	return fallback
end

-- Nombre fini quelconque, sinon repli (pour `now`).
local function finiteOr(value: unknown, fallback: number): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return fallback
end

-- ───────────────────────────────────────────────────────────────────────
-- :allow — tente de consommer un jeton pour (userId, name) à l'instant `now`
-- ───────────────────────────────────────────────────────────────────────

-- Retourne DEUX booléens :
--   1. allowed       — true si l'appel est autorisé (jeton consommé), false si rejeté.
--   2. firstRejection — true UNIQUEMENT sur la 1re frappe rejetée d'une rafale
--                       (transition autorisé→rejeté) ; false sinon (y compris
--                       autorisé, et rejets suivants de la même rafale). Le
--                       Service s'en sert pour warn une seule fois par rafale.
function RateLimiter.allow(
	self: RateLimiter,
	userId: number,
	name: string,
	capacity: number,
	refillPerSec: number,
	now: number
): (boolean, boolean)
	-- Défensif : entrées coercées, jamais de crash.
	if type(userId) ~= "number" or type(name) ~= "string" then
		return false, false -- clé inexploitable : on rejette sans état (fail-safe)
	end
	local cap = positiveOr(capacity, 1)
	local refill = positiveOr(refillPerSec, 1)
	local t = finiteOr(now, 0)

	local byUser = self.buckets[userId]
	if not byUser then
		byUser = {}
		self.buckets[userId] = byUser
	end

	local bucket = byUser[name]
	if not bucket then
		-- Premier appel : seau plein, ancré à `now`.
		bucket = { tokens = cap, lastRefill = t, rejecting = false }
		byUser[name] = bucket
	end

	-- Recharge paresseuse. math.max(0, …) : une horloge qui recule ne crée pas
	-- de jetons négatifs ni de bond en avant.
	local elapsed = math.max(0, t - bucket.lastRefill)
	bucket.tokens = math.min(cap, bucket.tokens + elapsed * refill)
	bucket.lastRefill = t

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		bucket.rejecting = false
		return true, false
	end

	-- Rejet. firstRejection = on n'était pas déjà en train de rejeter.
	local firstRejection = not bucket.rejecting
	bucket.rejecting = true
	return false, firstRejection
end

-- ───────────────────────────────────────────────────────────────────────
-- :removePlayer — libère tous les seaux d'un joueur (anti-fuite mémoire)
-- ───────────────────────────────────────────────────────────────────────

-- À appeler sur PlayerRemoving. Idempotent (userId inconnu → no-op).
function RateLimiter.removePlayer(self: RateLimiter, userId: number)
	self.buckets[userId] = nil
end

return RateLimiter
