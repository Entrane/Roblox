--!strict
-- RoundManager — Machine à états de la manche : colonne vertébrale temporelle.
-- États : Lobby → Starting → Playing → Resolved → Lobby → ...
--
-- ─── ROLE-IGNORANT (refonte PvP) ────────────────────────────────────────
-- RoundManager ne DÉCIDE PLUS qui gagne. Il ne CONSTRUIT JAMAIS une valeur
-- Faction : il ne fait que la RECEVOIR via onRoundResolved(winner) et la stocker.
-- C'est le SERVICE qui calcule le vainqueur à partir des conditions du monde
-- (échappées, survivants tous résolus, timer écoulé) et le transmet. Le module
-- ne sait même pas que « le timeout favorise l'Écho » — il sait juste compter le
-- temps et exposer timeRemaining ; c'est le Service qui, voyant le temps écoulé,
-- appelle onRoundResolved(Echo). Forme la plus stricte d'ignorance des rôles.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Ce module DÉCIDE des transitions ; il ne VA RIEN CHERCHER dans le monde.
-- Tous les événements dynamiques (joueur qui rejoint/quitte, manche résolue)
-- ENTRENT par appel de fonction. Aucune dépendance à Players, Workspace,
-- RunService, aux Remotes ni à un objet 3D.
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
-- dépendances comportementales. Les require sont volontairement ISOLÉS dans
-- l'unique bloc ci-dessous : un futur passage à l'injection (new(deps)) resterait
-- une modif chirurgicale, localisée ici.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local RoundManager = {}
RoundManager.__index = RoundManager

-- État interne + méthodes (via metatable). Pattern strict recommandé.
-- `winner` : faction gagnante POSÉE par onRoundResolved (en Playing) et appliquée
-- en phase Resolved par update. Remis à nil dès qu'on (re)part en Lobby/Playing.
export type RoundManager = typeof(setmetatable(
	{} :: {
		phase: Types.RoundPhase,
		timeRemaining: number, -- secondes restantes dans la phase courante
		players: { [number]: boolean }, -- ensemble des userId présents et suivis
		playerCount: number, -- nombre de joueurs présents (suivis)
		winner: Types.Faction?, -- vainqueur reçu du Service, ou nil tant que non résolu
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
	self.winner = nil
	return self
end

-- ───────────────────────────────────────────────────────────────────────
-- Transitions privées (entrée dans un état : pose phase + timer + drapeaux)
-- Chaque _enterX applique UNE transition. Préfixe _ = usage interne.
-- ───────────────────────────────────────────────────────────────────────

function RoundManager._enterLobby(self: RoundManager)
	self.phase = Types.RoundPhase.Lobby
	self.timeRemaining = GameConfig.Round.LobbyDuration
	self.winner = nil
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
	self.winner = nil -- repart d'une manche non résolue
end

-- État TERMINAL unique (ex-Victory/Defeat). `winner` est DÉJÀ posé par
-- onRoundResolved au moment où update déclenche cette entrée ; on ne fait que
-- caler le timer d'intermission. La faction décide de l'écran de fin, pas la phase.
function RoundManager._enterResolved(self: RoundManager)
	self.phase = Types.RoundPhase.Resolved
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
-- Les transitions éventuelles (T2 annulation, T5 abandon) sont résolues par update.
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

-- Le SERVICE signale que la manche est résolue et QUI a gagné. RoundManager ne
-- calcule rien : il enregistre la faction et laisse update appliquer la transition
-- Playing → Resolved (discipline « update est le seul point de transition »).
--
-- Gardes :
--   - N'a d'effet qu'en Playing (une résolution n'a de sens que manche en cours) ;
--   - winner doit être une Faction valide (sinon ignoré, défensif) ;
--   - IDEMPOTENT « premier arrivé gagne » : si un vainqueur est déjà posé, les
--     appels suivants sont ignorés. C'est CE garde qui fait gagner la victoire
--     survivant contre le timeout quand les deux tombent le même tick : le Service
--     teste la victoire AVANT le timeout et appelle onRoundResolved(Survivors) en
--     premier ; un éventuel onRoundResolved(Echo) du watcher timeout est alors
--     ignoré ici.
function RoundManager.onRoundResolved(self: RoundManager, winner: Types.Faction)
	if self.phase ~= Types.RoundPhase.Playing then
		return
	end
	if winner ~= Types.Faction.Survivors and winner ~= Types.Faction.Echo then
		return -- faction inconnue : on n'enregistre rien
	end
	if self.winner ~= nil then
		return -- premier vainqueur verrouillé
	end
	self.winner = winner
end

-- ───────────────────────────────────────────────────────────────────────
-- update — SEUL point d'application des transitions
-- ───────────────────────────────────────────────────────────────────────

-- À appeler à chaque tick serveur. Avance le timer de la phase et applique AU
-- PLUS UNE transition par appel (pas d'enchaînement en cascade dans le même tick).
function RoundManager.update(self: RoundManager, dt: number)
	-- Défensif : dt invalide (nil, non-nombre, NaN, ≤ 0) → traité comme 0. On
	-- n'avance pas les timers, mais on évalue quand même les transitions
	-- conditionnelles (T1/T2/T4/T5), qui ne dépendent pas du temps.
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
		-- T5 : plus aucun joueur → abandon direct vers Lobby (aucun écran, on
		-- JETTE tout vainqueur éventuel : serveur vide, personne à qui l'afficher).
		if self.playerCount <= 0 then
			self:_enterLobby()
		-- T4 : la manche est résolue (winner posé par le Service via onRoundResolved).
		-- Vérifié AVANT le timer : une résolution gagne toujours la course au temps.
		elseif self.winner ~= nil then
			self:_enterResolved()
		else
			-- Décompte du garde-fou de durée. PLUS d'auto-résolution ici : à
			-- expiration, on RESTE en Playing (timer clampé). C'est le Service qui,
			-- voyant timeRemaining ≤ 0, appellera onRoundResolved(Echo). Le module
			-- reste role-ignorant (il ne nomme aucune faction).
			self.timeRemaining -= delta
			if self.timeRemaining < 0 then
				self.timeRemaining = 0
			end
		end

	elseif phase == Types.RoundPhase.Resolved then
		-- T6 : fin de l'intermission → retour au Lobby.
		self.timeRemaining -= delta
		if self.timeRemaining <= 0 then
			self:_enterLobby()
		end
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- Lecture (pure, sans effet de bord) — l'appelant lit et compare lui-même
-- ───────────────────────────────────────────────────────────────────────

-- Snapshot destiné à être répliqué aux clients (HUD : phase + temps + vainqueur).
-- INVARIANT exposé : winner non-nil SI ET SEULEMENT SI phase == Resolved. On
-- masque ici tout vainqueur transitoire posé pendant un même tick Playing (entre
-- onRoundResolved et l'application de la transition par update).
function RoundManager.getState(self: RoundManager): Types.RoundState
	return {
		phase = self.phase,
		timeRemaining = math.max(self.timeRemaining, 0), -- jamais négatif à l'affichage
		winner = if self.phase == Types.RoundPhase.Resolved then self.winner else nil,
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
