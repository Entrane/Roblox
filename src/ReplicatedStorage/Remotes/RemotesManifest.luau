--!strict
-- RemotesManifest — Création et accès centralisés des RemoteEvents.
-- Requis des DEUX côtés : le SERVEUR crée les RemoteEvents s'ils manquent, le
-- CLIENT les attend (WaitForChild). Un seul endroit déclare le contrat réseau,
-- et le WaitForChild côté client absorbe la course serveur/client.
--
-- ⚠️ NON EXÉCUTABLE HORS STUDIO : ce module est 100 % API Roblox (RemoteEvent,
-- Instance.new, RunService:IsServer, WaitForChild). Il ne peut être validé
-- qu'en Studio ; luau-analyze ne vérifie que la cohérence de types, pas le
-- comportement réseau. ⚠️ À VALIDER DANS STUDIO.
--
-- ─── DEUX SENS DE COMMUNICATION ─────────────────────────────────────────
-- Un RemoteEvent est techniquement BIDIRECTIONNEL : le SENS naît de l'usage
-- (FireServer/OnServerEvent côté client→serveur ; FireClient/OnClientEvent côté
-- serveur→client), pas de sa création. ensureEvent crée donc tous les Remotes
-- à l'identique ; ci-dessous on les GROUPE par sens à titre de contrat.
--
-- ─── AUTORITÉ SERVEUR (client → serveur) ────────────────────────────────
-- Pour les Remotes montants, le serveur n'utilise QUE le Player fourni par
-- OnServerEvent pour l'IDENTITÉ ; aucun userId reçu du client n'est cru comme
-- identité (voir PlayerService/EchoService). ActivateAbility exige en plus que
-- l'émetteur SOIT l'Écho courant (EchoService : player.UserId ==
-- RoleManager.getEchoUserId()), sinon ignoré.
--
-- ─── ANTI-TRICHE (serveur → client) ─────────────────────────────────────
-- ⚠️ Echolocation, EchoState et AssignRole sont DESCENDANTS et CIBLÉS : émis
-- UNIQUEMENT via FireClient(joueurConcerné, …), JAMAIS FireAllClients. Le
-- RemotesManifest ne peut pas l'imposer au runtime (il ne fait que créer
-- l'instance) : l'enforcement réel est dans EchoService, SEUL émetteur, qui
-- résout le destinataire (l'Écho via RoleManager.getEchoUserId()) et ne tire
-- qu'à lui. Propriété clé : la donnée (positions des survivants) ne QUITTE
-- JAMAIS le serveur pour un autre client — ce n'est pas « envoyer à tous puis
-- cacher côté client » (exploitable), c'est « envoyer à exactement un joueur »
-- (décision #9, non négociable).
--
-- ⚠️ TODO PERF : UnreliableRemoteEvent à envisager pour Echolocation si une
-- latence est mesurée en Studio — flux positionnel à ~2 Hz, idempotent (un
-- pulse perdu est rattrapé au suivant), donc tolérant à la perte et plus léger
-- en bande passante. RemoteEvent fiable pour le MVP.

local RunService = game:GetService("RunService")

-- script.Parent = dossier ReplicatedStorage.Remotes (ce module en est l'enfant).
local container = script.Parent
local IS_SERVER = RunService:IsServer()

-- Noms canoniques des RemoteEvents, GROUPÉS par sens (création identique).
local EVENT_NAMES = {
	-- ── Client → serveur (intentions joueur, identité = Player serveur) ──
	"SetSprinting", -- (wants: boolean) — survivant
	"SetTorch", -- (on: boolean) — survivant
	"SetReviving", -- (targetUserId: number) — survivant ; cible DONNÉE, revalidée serveur
	"StopReviving", -- () — survivant ; le sauveteur relâche
	"ActivateAbility", -- (abilityId: string=Types.AbilityId) — ÉCHO ; émetteur revalidé == Écho

	-- ── Serveur → client (poussés, CIBLÉS, jamais FireAllClients) ──
	"Echolocation", -- (pings: {Types.EcholocationPing}) — au SEUL client Écho, au pulse
	"EchoState", -- (state: Types.EchoState) — au SEUL client Écho, jauges HUD
	"AssignRole", -- (role: Types.Role) — au joueur concerné, au démarrage de manche

	-- ── Serveur → client (HUD, ~10 Hz throttlé) ──
	"RoundState", -- (state: Types.RoundState) — FireAllClients ; phase/timer/winner
	"FuseProgress", -- (progress: Types.FuseProgress) — FireAllClients ; x/5
	"PlayerHud", -- (state: Types.HudPlayerState) — FireClient au SEUL joueur concerné
}

-- Trouve le RemoteEvent ; le crée côté serveur, l'attend côté client.
local function ensureEvent(name: string): RemoteEvent
	local existing = container:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), `Remotes.{name} existe mais n'est pas un RemoteEvent`)
		return existing
	end
	if IS_SERVER then
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = container
		return event
	end
	return container:WaitForChild(name) :: RemoteEvent
end

export type Remotes = {
	-- Client → serveur
	SetSprinting: RemoteEvent,
	SetTorch: RemoteEvent,
	SetReviving: RemoteEvent,
	StopReviving: RemoteEvent,
	ActivateAbility: RemoteEvent,
	-- Serveur → client (ciblés)
	Echolocation: RemoteEvent,
	EchoState: RemoteEvent,
	AssignRole: RemoteEvent,
	-- Serveur → client (HUD)
	RoundState: RemoteEvent,
	FuseProgress: RemoteEvent,
	PlayerHud: RemoteEvent,
}

local Remotes = {} :: Remotes
for _, name in EVENT_NAMES do
	(Remotes :: any)[name] = ensureEvent(name)
end

return Remotes
