--!strict
-- RoundManager — Machine à états de la manche : colonne vertébrale temporelle.
-- États : Lobby → Starting → Playing → (Victory | Defeat) → Lobby → ...
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Ce module DÉCIDE des transitions ; il ne VA RIEN CHERCHER dans le monde.
-- Tous les événements dynamiques (joueur qui rejoint/quitte, objectif atteint,
-- tous les joueurs à terre) ENTRENT par appel de fonction. Aucune dépendance à
-- Players, Workspace, RunService, aux Remotes ni à un objet 3D.
--
-- Le module est PASSIF : il ne notifie personne. Détecter un changement de phase
-- est la RESPONSABILITÉ DE L'APPELANT (le Service), par comparaison à chaque tick :
--     local avant = round:getPhase()
--     round:update(dt)
--     if round:getPhase() ~= avant then ... réagir ... end
-- Choix délibéré : pas de callback (qui exécuterait du code de Service AU MILIEU
-- d'une transition → risque de réentrée intestable) ni de valeurs de retour
-- dispersées. update() est le SEUL point où une transition s'applique.
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- ⚠️ À VALIDER DANS STUDIO : ce module require deux modules PURS et sans effet
-- de bord depuis ReplicatedStorage — GameConfig (constantes de réglage) et Types
-- (contrat de données + constantes d'enum). Localiser ces modules partagés
-- nécessite une référence à ReplicatedStorage : c'est le SEUL endroit où
-- RoundManager touche `game`, uniquement pour CHARGER le contrat partagé, jamais
-- pour lire un état du monde. On reste sur le contexte SERVEUR (les enfants de
-- ReplicatedStorage sont présents au chargement). Le chemin require est à
-- confirmer dès la première synchro Rojo.
--
-- CHOIX ASSUMÉ — require plutôt qu'injection (uniforme sur tous les modules
-- Logic) : GameConfig et Types sont des CONSTANTES/TYPES figés, pas des
-- dépendances comportementales. Les charger est une entorse mineure, pas le
-- couplage que la règle de pureté visait à interdire. Les require sont
-- volontairement ISOLÉS dans l'unique bloc ci-dessous : un futur passage à
-- l'injection (new(deps)) resterait une modif chirurgicale, localisée ici.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local RoundManager = {}
RoundManager.__index = RoundManager

-- État interne + méthodes (via metatable). Pattern strict recommandé.
export type RoundManager = typeof(setmetatable(
	{} :: {
		phase: Types.RoundPhase,
		timeRemaining: number, -- secondes restantes dans la phase courante
		players: { [number]: boolean }, -- ensemble des userId présents et suivis
		playerCount: number, -- nombre de joueurs présents (suivis)
		objectiveComplete: boolean, -- intention : sortie atteinte (résolue en Playing)
		allDowned: boolean, -- intention : tous les actifs à terre (résolue en Playing)
	},
	RoundManager
))

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

-- Crée une instance autonome (pas de singleton global → testable en isolation).
-- État initial : Lobby, aucun joueur. Aucun effet de bord.
function RoundManager.new(): RoundManager
	local self = setmetatable({}, RoundManager) :: RoundManager
	self.phase = Types.RoundPhase.Lobby
	self.timeRemaining = GameConfig.Round.LobbyDuration
	self.players = {}
	self.playerCount = 0
	self.objectiveComplete = false
	self.allDowned = false
	return self
end

-- ───────────────────────────────────────────────────────────────────────
-- Transitions privées (entrée dans un état : pose phase + timer + drapeaux)
-- Chaque _enterX applique UNE transition. Préfixe _ = usage interne.
-- ───────────────────────────────────────────────────────────────────────

function RoundManager._enterLobby(self: RoundManager)
	self.phase = Types.RoundPhase.Lobby
	self.timeRemaining = GameConfig.Round.LobbyDuration
	self.objectiveComplete = false
	self.allDowned = false
	-- NB : on CONSERVE `players` — les joueurs encore présents serviront à
	-- recompter pour la manche suivante (T1 redéclenchera au prochain update).
end

function RoundManager._enterStarting(self: RoundManager)
	self.phase = Types.RoundPhase.Starting
	self.timeRemaining = GameConfig.Round.LobbyDuration -- décompte avant départ
end

function RoundManager._enterPlaying(self: RoundManager)
	self.phase = Types.RoundPhase.Playing
	self.timeRemaining = GameConfig.Round.MaxRoundDuration -- garde-fou de durée
	-- Repart d'intentions vierges pour la nouvelle manche.
	self.objectiveComplete = false
	self.allDowned = false
end

function RoundManager._enterVictory(self: RoundManager)
	self.phase = Types.RoundPhase.Victory
	self.timeRemaining = GameConfig.Round.IntermissionDuration
end

function RoundManager._enterDefeat(self: RoundManager)
	self.phase = Types.RoundPhase.Defeat
	self.timeRemaining = GameConfig.Round.IntermissionDuration
end

-- ───────────────────────────────────────────────────────────────────────
-- Événements entrants (le monde appelle ; le module se contente d'enregistrer)
-- ───────────────────────────────────────────────────────────────────────

-- Un joueur rejoint. Renvoie true s'il est ADMIS comme participant de la manche
-- courante (uniquement en Lobby/Starting), false s'il doit être SPECTATEUR.
-- Dans tous les cas, sa présence est suivie (il participera à la manche suivante).
-- Idempotent : un userId déjà suivi n'est pas recompté.
function RoundManager.onPlayerJoined(self: RoundManager, userId: number): boolean
	-- Défensif : userId doit être un nombre.
	if type(userId) ~= "number" then
		return false
	end

	-- Suivi de présence (même un spectateur est suivi pour la manche suivante).
	if not self.players[userId] then
		self.players[userId] = true
		self.playerCount += 1
	end

	-- Admission active uniquement quand la manche n'a pas encore commencé.
	return self.phase == Types.RoundPhase.Lobby or self.phase == Types.RoundPhase.Starting
end

-- Un joueur quitte. Retire son suivi. Inconnu (jamais suivi ou déjà parti) → ignoré.
-- Les transitions éventuelles (T2 annulation, T7 abandon) sont résolues par update.
function RoundManager.onPlayerLeft(self: RoundManager, userId: number)
	if type(userId) ~= "number" then
		return
	end
	if not self.players[userId] then
		return -- inconnu : anti-crash / anti-double-décompte
	end
	self.players[userId] = nil
	self.playerCount -= 1
	if self.playerCount < 0 then
		self.playerCount = 0 -- garde-fou (ne devrait jamais arriver)
	end
end

-- Signale que l'objectif est atteint (sortie atteinte, courant rétabli).
-- N'a d'effet qu'en Playing (sinon gardé/ignoré). Idempotent.
-- NB : ce n'est PAS « 5 fusibles déposés » (ça, c'est un jalon de FuseSystem),
-- mais bien « sortie atteinte ». La transition réelle s'applique dans update().
function RoundManager.onObjectiveComplete(self: RoundManager)
	if self.phase == Types.RoundPhase.Playing then
		self.objectiveComplete = true
	end
end

-- Signale que tous les participants actifs sont à terre/morts.
-- C'est PlayerService qui DÉTECTE la condition et l'appelle (RoundManager ne la
-- calcule pas). N'a d'effet qu'en Playing. Idempotent.
function RoundManager.onAllPlayersDowned(self: RoundManager)
	if self.phase == Types.RoundPhase.Playing then
		self.allDowned = true
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- update — SEUL point d'application des transitions
-- ───────────────────────────────────────────────────────────────────────

-- À appeler à chaque tick serveur. Avance le timer de la phase et applique AU
-- PLUS UNE transition par appel (pas d'enchaînement en cascade dans le même tick).
function RoundManager.update(self: RoundManager, dt: number)
	-- Défensif : dt invalide (nil, non-nombre, NaN, ≤ 0) → traité comme 0. On
	-- n'avance pas les timers, mais on évalue quand même les transitions
	-- conditionnelles (T1/T2/T7), qui ne dépendent pas du temps.
	local delta: number = if type(dt) == "number" and dt > 0 then dt else 0

	local phase = self.phase
	local minPlayers = GameConfig.Player.MinPlayers

	if phase == Types.RoundPhase.Lobby then
		-- T1 : assez de joueurs → lancer le décompte.
		if self.playerCount >= minPlayers then
			self:_enterStarting()
		end
		-- Sinon : attente indéfinie, le timer ne tourne pas.

	elseif phase == Types.RoundPhase.Starting then
		-- T2 : repassé sous le seuil → annuler le décompte.
		if self.playerCount < minPlayers then
			self:_enterLobby()
		else
			self.timeRemaining -= delta
			if self.timeRemaining <= 0 then
				self:_enterPlaying() -- T3
			end
		end

	elseif phase == Types.RoundPhase.Playing then
		-- T7 : plus aucun joueur → abandon direct vers Lobby (aucun écran).
		if self.playerCount <= 0 then
			self:_enterLobby()
		-- T4 : la victoire GAGNE LA COURSE — vérifiée AVANT le timeout.
		elseif self.objectiveComplete then
			self:_enterVictory()
		-- T5 : tous les actifs à terre.
		elseif self.allDowned then
			self:_enterDefeat()
		else
			-- T6 : garde-fou de durée maximale.
			self.timeRemaining -= delta
			if self.timeRemaining <= 0 then
				self:_enterDefeat()
			end
		end

	elseif phase == Types.RoundPhase.Victory or phase == Types.RoundPhase.Defeat then
		-- T8 / T9 : fin de l'intermission → retour au Lobby.
		self.timeRemaining -= delta
		if self.timeRemaining <= 0 then
			self:_enterLobby()
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Lecture (pure, sans effet de bord) — l'appelant lit et compare lui-même
-- ───────────────────────────────────────────────────────────────────────

-- Snapshot destiné à être répliqué aux clients (HUD : phase + temps restant).
function RoundManager.getState(self: RoundManager): Types.RoundState
	return {
		phase = self.phase,
		timeRemaining = math.max(self.timeRemaining, 0), -- jamais négatif à l'affichage
	}
end

function RoundManager.getPhase(self: RoundManager): Types.RoundPhase
	return self.phase
end

-- Nombre de joueurs présents et suivis (participants + futurs participants).
function RoundManager.getPlayerCount(self: RoundManager): number
	return self.playerCount
end

return RoundManager
