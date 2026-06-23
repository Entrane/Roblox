--!strict
-- RoundService — Pilote RoundManager (Logic) : l'instancie, le connecte aux
-- vrais évènements joueurs, fait avancer update(dt) à chaque tick serveur, et
-- réagit aux changements de phase en touchant le monde (téléportation).
--
-- ─── RoundManager reste PASSIF ──────────────────────────────────────────
-- RoundManager ne notifie personne (voir ses propres commentaires). C'est ICI,
-- au Service, que la transition est détectée : comparaison phase avant/après
-- update(), jamais de callback. C'est le SEUL endroit du projet qui fait
-- cette comparaison.
--
-- ─── RoundManager ET RoundService SONT ROLE-IGNORANTS ───────────────────
-- RoundManager ne décide plus qui gagne : il reçoit la faction via
-- onRoundResolved(winner) et applique Playing → Resolved. RoundService NE NOMME
-- PLUS AUCUNE FACTION non plus : il n'expose qu'un point d'entrée neutre,
-- signalRoundResolved(winner), relayé tel quel à RoundManager. Le calcul DU
-- vainqueur (survivants tous résolus / évasion / timeout) est centralisé dans
-- PlayerService, SEUL calculateur (décision #4) — y compris le timeout, qui y a
-- été DÉPLACÉ pour que la résolution survivants gagne la course au temps.
--
-- ─── AUTONOMIE vis-à-vis de FuseSystem / PlayerState ────────────────────
-- Ce Service ne require ni FuseSystem ni PlayerState et n'a pas besoin de les
-- connaître : il n'expose que signalRoundResolved. Même discipline de
-- découplage que celle tenue entre les modules Logic.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundManager = require(ServerStorage.Logic.RoundManager)
local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)

local RoundService = {}

-- Réplication HUD : RoundState (phase/timer/winner) poussé à TOUS, throttlé.
local HUD_INTERVAL = 0.1 -- s (~10 Hz)
local hudAccum = 0

-- Instance UNIQUE partagée (pas un singleton global au sens Lua — juste une
-- upvalue de module, comme RoundManager.new() le permet pour les tests). Les
-- futurs Services la récupèrent via RoundService.getRoundManager().
local roundManager: RoundManager.RoundManager = RoundManager.new()

-- Dernière phase observée par CE Service (pas par RoundManager, qui n'a pas
-- cette notion). Initialisée depuis l'état réel plutôt qu'en dur, pour ne pas
-- dupliquer la connaissance de la phase de départ de RoundManager.
local lastPhase: Types.RoundPhase = roundManager:getPhase()

local initialized = false

-- ───────────────────────────────────────────────────────────────────────
-- Monde : téléportation au point de rassemblement
-- ───────────────────────────────────────────────────────────────────────

-- Téléporte tous les joueurs connectés à Workspace.Map.SpawnPoint.
-- Lobby/Starting/Playing réutilisent le même point de rassemblement (la map
-- n'a pas de zone de lobby séparée) : c'est aussi notre "reset visuel" entre
-- deux manches.
-- Défensif (Map/SpawnPoint absent, personnage pas encore chargé) : on logue et
-- on continue, on ne lève jamais d'erreur ici (voir tick() pour pourquoi c'est
-- important).
local function teleportAllPlayersToSpawn()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		warn("[RoundService] Workspace.Map introuvable : téléportation ignorée.")
		return
	end

	local spawnPoint = map:FindFirstChild("SpawnPoint")
	if not spawnPoint or not spawnPoint:IsA("BasePart") then
		warn("[RoundService] Workspace.Map.SpawnPoint introuvable : téléportation ignorée.")
		return
	end

	-- Décalage vertical : on pose le joueur AU-DESSUS du pad, pas à son centre
	-- (le centre d'un SpawnLocation est à mi-hauteur de sa Part).
	local spawnCFrame = spawnPoint.CFrame + Vector3.new(0, spawnPoint.Size.Y / 2 + 3, 0)

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			character:PivotTo(spawnCFrame)
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Réaction aux transitions de phase (détectées dans tick(), voir plus bas)
-- ───────────────────────────────────────────────────────────────────────

local function onPhaseChanged(previous: Types.RoundPhase, current: Types.RoundPhase)
	-- Trace de TOUTES les transitions : seul endroit du projet qui les détecte
	-- (RoundManager reste passif). Permet de suivre le déroulé d'une manche en
	-- Studio sans interface, et restera utile au debug une fois le HUD en place.
	print(string.format("[RoundService] Transition de phase : %s -> %s", previous, current))

	if current == Types.RoundPhase.Lobby or current == Types.RoundPhase.Starting or current == Types.RoundPhase.Playing then
		teleportAllPlayersToSpawn()
	end

	-- Resolved : aucune action sur le monde — les joueurs restent où l'instant
	-- les a trouvés. Le vainqueur est lisible via getState().winner ; l'écran de
	-- fin (paramétré par la faction) viendra avec le HUD. La trace ci-dessus
	-- suffit à tester en Studio.
end

-- ───────────────────────────────────────────────────────────────────────
-- Tick serveur — SEUL endroit qui compare phase avant/après update()
-- ───────────────────────────────────────────────────────────────────────

local function tick(dt: number)
	local previous = lastPhase
	roundManager:update(dt)
	local current = roundManager:getPhase()

	-- On resynchronise lastPhase AVANT de réagir. Si onPhaseChanged plantait
	-- (Map mal renommée, etc.), Roblox logue l'erreur mais ne déconnecte PAS
	-- le Heartbeat — sans cette ligne avant l'appel, la même transition
	-- semblerait "encore non traitée" au tick suivant et onPhaseChanged
	-- rejouerait en boucle à 60 appels/seconde.
	lastPhase = current

	if current ~= previous then
		onPhaseChanged(previous, current)
		-- HUD : transition de phase répliquée IMMÉDIATEMENT (phase/winner snappy).
		Remotes.RoundState:FireAllClients(roundManager:getState())
		hudAccum = 0
	end

	-- HUD : push throttlé du RoundState (le client décompte le timer en local
	-- entre deux pushes et resync ici). Poussé dans TOUTES les phases (lobby inclus).
	hudAccum += dt
	if hudAccum >= HUD_INTERVAL then
		hudAccum -= HUD_INTERVAL
		Remotes.RoundState:FireAllClients(roundManager:getState())
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Joueurs : présence suivie par RoundManager
-- ───────────────────────────────────────────────────────────────────────

local function onPlayerJoined(player: Player)
	roundManager:onPlayerJoined(player.UserId)
end

local function onPlayerLeft(player: Player)
	roundManager:onPlayerLeft(player.UserId)
end

-- ───────────────────────────────────────────────────────────────────────
-- Interface publique
-- ───────────────────────────────────────────────────────────────────────

-- Lecture : pas de wrappers ici. Les futurs Services lisent l'état via l'API
-- déjà publique de RoundManager (getPhase/getState/getPlayerCount) sur
-- l'instance renvoyée, plutôt que via des doublons maintenus dans ce module.
function RoundService.getRoundManager(): RoundManager.RoundManager
	return roundManager
end

-- Point d'entrée NEUTRE de résolution : RoundService ne nomme aucune faction, il
-- relaie le vainqueur calculé par PlayerService (décision #4). RoundManager
-- applique Playing → Resolved (Playing-gated, idempotent « premier verrouillé »).
function RoundService.signalRoundResolved(winner: Types.Faction)
	roundManager:onRoundResolved(winner)
end

-- Point d'entrée unique. Appelé une seule fois par init.server.luau.
function RoundService.init()
	if initialized then
		return
	end
	initialized = true

	-- Couvre les joueurs déjà connectés avant ce branchement (Play Solo,
	-- recompilation à chaud) : sans cette boucle, un PlayerAdded déjà passé
	-- serait perdu et ce joueur ne compterait jamais pour MinPlayers.
	for _, player in Players:GetPlayers() do
		onPlayerJoined(player)
	end
	Players.PlayerAdded:Connect(onPlayerJoined)
	Players.PlayerRemoving:Connect(onPlayerLeft)

	RunService.Heartbeat:Connect(tick)
end

return RoundService
