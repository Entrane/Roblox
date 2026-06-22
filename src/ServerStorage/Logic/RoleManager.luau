--!strict
-- RoleManager — Affectation des rôles (PvP 4v1) et rotation de l'Écho humain.
-- Décide QUI est Survivor / Echo pour la manche, et maintient une file « chacun
-- son tour » désignant le prochain humain candidat au rôle d'Écho.
--
-- ─── PURETÉ & PASSIVITÉ ─────────────────────────────────────────────────
-- Module PUR : aucune donnée 3D, aucune Instance Roblox, aucune lecture du monde.
-- Tout ce qui est dynamique (joueur qui rejoint/quitte, démarrage de manche)
-- ENTRE par appel de fonction. Aucune dépendance à Players/Workspace/Remotes.
--
-- PASSIF, comme RoundManager / PlayerState / FuseSystem : il ne notifie personne
-- et n'appelle aucun autre module Logic. Il EXPOSE des requêtes (getRole,
-- getEchoUserId, isHumanEcho…) que le Service lit et sur lesquelles le Service
-- agit. RoleManager ne connaît NI RoundManager, NI EntityAI, NI EchoController.
--
-- Pas de update(dt) : RoleManager n'a AUCUNE notion de temps. C'est un module
-- purement événementiel — l'affectation est calculée d'un coup, au démarrage de
-- manche (assignRoles), jamais progressivement tick par tick.
--
-- ─── DEUX NOTIONS D'ÉTAT À NE PAS CONFONDRE ─────────────────────────────
--   1. AFFECTATION COURANTE (durée d'une manche) : pour chaque userId, son Role,
--      plus echoUserId/humanEcho — repartie à zéro par resetRoundAssignment et
--      recalculée par assignRoles.
--   2. FILE DE ROTATION (durée de la session, persiste entre manches) : ordre de
--      passage FIFO des humains pour le rôle d'Écho. Jamais vidée explicitement ;
--      seulement alimentée par onPlayerJoined et purgée par onPlayerLeft.
--
-- ─── DÉCISIONS DE DESIGN ACTÉES (exécution concrète CÔTÉ SERVICE) ────────
-- ⚠️ DÉCISION #7 — Le MODE (Écho humain vs Écho IA) est figé AU DÉMARRAGE de
-- manche, dans assignRoles, par comparaison à GameConfig.Roles.HumanEchoMinPlayers.
-- Un effectif qui repasse sous le seuil EN COURS de manche NE rebascule PAS :
-- assignRoles n'est pas rappelé avant la manche suivante.
--
-- ⚠️ DÉCISION — « L'Écho HUMAIN quitte PENDANT la manche » → bascule immédiate
-- sur l'Écho IA (EntityAI) pour le RESTE de la manche en cours. PAS d'annulation,
-- PAS de victoire par défaut aux survivants. RoleManager ne fait qu'enregistrer
-- le départ (onPlayerLeft efface l'affectation Echo et met humanEcho à false) ;
-- la bascule effective sur l'IA est de la responsabilité du Service/EchoController,
-- qui DÉTECTE — en lisant isHumanEcho()/getEchoUserId() après onPlayerLeft — que
-- l'humain Écho a disparu et reprend la main avec EntityAI. Décision documentée
-- ICI pour qu'elle ne se perde pas d'ici à ce qu'on code le Service.
--
-- ⚠️ HYPOTHÈSE — EchoCount = 1 assumé : l'API est SINGULIÈRE (getEchoUserId).
-- Si GameConfig.Roles.EchoCount passait à plusieurs, l'API devrait être revue
-- (getEchoUserIds pluriel). Non géré tant que EchoCount = 1.
--
-- ─── DÉPENDANCES (à valider en Studio) ──────────────────────────────────
-- CHOIX ASSUMÉ — require uniforme (vs injection), comme tous les modules Logic.
-- GameConfig (seuils) et Types (Role) sont des constantes/types figés. Les
-- require sont volontairement ISOLÉS dans l'unique bloc ci-dessous.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.GameConfig)
local Types = require(Shared.Types)

local RoleManager = {}
RoleManager.__index = RoleManager

-- État interne :
--   queue      = file de rotation FIFO (ordre de passage des humains à l'Écho) ;
--   roles      = affectation courante userId -> Role (vide hors manche) ;
--   echoUserId = raccourci : userId de l'Écho humain courant, nil si Écho IA ou
--                hors manche (évite de re-scanner `roles` à chaque lecture) ;
--   humanEcho  = vrai uniquement si un humain incarne l'Écho cette manche.
export type RoleManager = typeof(setmetatable(
	{} :: {
		queue: { number },
		roles: { [number]: Types.Role },
		echoUserId: number?,
		humanEcho: boolean,
	},
	RoleManager
))

-- ───────────────────────────────────────────────────────────────────────
-- Helpers privés (file de rotation)
-- ───────────────────────────────────────────────────────────────────────

-- Index de userId dans la file, ou nil s'il n'y est pas. Scan O(n) : n ≤
-- MaxPlayers (petit), négligeable.
local function indexInQueue(self: RoleManager, userId: number): number?
	for i, id in self.queue do
		if id == userId then
			return i
		end
	end
	return nil
end

-- ───────────────────────────────────────────────────────────────────────
-- Construction
-- ───────────────────────────────────────────────────────────────────────

-- Instance autonome (pas de singleton → testable en isolation). File vide,
-- aucune affectation, Écho IA par défaut (humanEcho = false). Aucun effet de bord.
function RoleManager.new(): RoleManager
	local self = setmetatable({}, RoleManager) :: RoleManager
	self.queue = {}
	self.roles = {}
	self.echoUserId = nil
	self.humanEcho = false
	return self
end

-- ───────────────────────────────────────────────────────────────────────
-- Événements entrants (présence des joueurs)
-- ───────────────────────────────────────────────────────────────────────

-- Un joueur rejoint la session : ajouté en FIN de file (il attend son tour comme
-- les autres). Idempotent : un userId déjà dans la file n'est pas dupliqué.
-- GARANTIE (cf. cas limite « file vide ») : le Service appelle onPlayerJoined
-- pour TOUT joueur avant qu'il puisse figurer dans un assignRoles — la file ne
-- peut donc jamais être vide alors que des joueurs existent.
function RoleManager.onPlayerJoined(self: RoleManager, userId: number)
	if type(userId) ~= "number" then
		return
	end
	if indexInQueue(self, userId) ~= nil then
		return -- doublon ignoré silencieusement
	end
	table.insert(self.queue, userId)
end

-- Un joueur quitte : retiré de la file (où qu'il soit) ET de l'affectation
-- courante. S'il était l'Écho HUMAIN, on efface ce rôle et on repasse en Écho IA
-- (humanEcho = false, echoUserId = nil) — voir la DÉCISION « l'Écho humain quitte
-- pendant la manche » en tête de fichier : c'est le Service qui, lisant cet état,
-- bascule effectivement sur EntityAI. Inconnu → no-op silencieux.
function RoleManager.onPlayerLeft(self: RoleManager, userId: number)
	if type(userId) ~= "number" then
		return
	end

	local i = indexInQueue(self, userId)
	if i ~= nil then
		table.remove(self.queue, i) -- décale proprement, pas de trou
	end

	self.roles[userId] = nil

	-- ⚠️ COUPLAGE FRAGILE — NE PAS SUPPRIMER CE BLOC. echoUserId est un raccourci
	-- MÉMORISÉ (pas recalculé à la lecture, cf. note sur le champ dans le type).
	-- Si l'Écho humain part et qu'on OUBLIE de remettre echoUserId/humanEcho à zéro
	-- ici, getEchoUserId() continuera de renvoyer un userId FANTÔME (joueur déjà
	-- déconnecté) et isHumanEcho() restera true à tort → le Service ne basculerait
	-- jamais sur l'Écho IA (cf. DÉCISION « l'Écho humain quitte » en tête de
	-- fichier). C'est le SEUL endroit qui maintient cet invariant : toute lecture de
	-- echoUserId en dépend.
	if self.echoUserId == userId then
		self.echoUserId = nil
		self.humanEcho = false
	end
end

-- ───────────────────────────────────────────────────────────────────────
-- assignRoles — POINT D'ENTRÉE UNIQUE de l'affectation (démarrage de manche)
-- ───────────────────────────────────────────────────────────────────────

-- Calcule l'affectation de la manche à partir des joueurs RÉELLEMENT présents au
-- démarrage (playerIds, fournis par le Service). Repart toujours d'une affectation
-- vierge. Fige le MODE (humain/IA) ici et seulement ici (décision #7).
--
-- Règle :
--   - #playerIds >= GameConfig.Roles.HumanEchoMinPlayers → ÉCHO HUMAIN : on prend
--     le premier de la file présent parmi playerIds, on le désigne Echo, on le
--     fait TOURNER en fin de file ; tous les autres playerIds sont Survivor.
--   - sinon → ÉCHO IA : personne n'a le rôle Echo ; tous playerIds sont Survivor.
--     Le Service, voyant isHumanEcho() == false, pilote l'IA via EntityAI.
--
-- Défensif : un même userId présent en double dans playerIds est ignoré (traité
-- une seule fois). Un userId de playerIds absent de la file (le Service aurait
-- omis onPlayerJoined) est quand même affecté Survivor, mais ne peut pas être
-- choisi Écho (il n'est pas dans l'ordre de rotation) — garde-fou, pas un mode
-- de fonctionnement nominal.
function RoleManager.assignRoles(self: RoleManager, playerIds: { number })
	-- Affectation vierge à chaque manche.
	self.roles = {}
	self.echoUserId = nil
	self.humanEcho = false

	if type(playerIds) ~= "table" then
		return
	end

	-- Ensemble des présents (dédoublonne les éventuels doublons de playerIds).
	local present: { [number]: boolean } = {}
	local count = 0
	for _, userId in playerIds do
		if type(userId) == "number" and not present[userId] then
			present[userId] = true
			count += 1
		end
	end

	-- Choix de l'Écho HUMAIN : seulement si l'effectif atteint le seuil. On suit
	-- l'ORDRE DE LA FILE et on prend le premier candidat effectivement présent
	-- (un humain en tête de file mais absent de cette manche est sauté).
	local chosenEcho: number? = nil
	if count >= GameConfig.Roles.HumanEchoMinPlayers then
		for _, userId in self.queue do
			if present[userId] then
				chosenEcho = userId
				break
			end
		end
	end

	-- Affecte tout le monde : l'élu en Echo, le reste en Survivor.
	for userId in present do
		if userId == chosenEcho then
			self.roles[userId] = Types.Role.Echo
		else
			self.roles[userId] = Types.Role.Survivor
		end
	end

	-- Fige le mode et fait tourner la file (rotation « chacun son tour »).
	if chosenEcho ~= nil then
		self.echoUserId = chosenEcho
		self.humanEcho = true
		-- Rotation : l'Écho de cette manche repart en FIN de file.
		local i = indexInQueue(self, chosenEcho)
		if i ~= nil then
			table.remove(self.queue, i)
			table.insert(self.queue, chosenEcho)
		end
	end
end

-- Vide UNIQUEMENT l'affectation courante (pas la file), pour repartir propre
-- avant un nouvel assignRoles. La file de rotation, elle, persiste entre manches.
function RoleManager.resetRoundAssignment(self: RoleManager)
	self.roles = {}
	self.echoUserId = nil
	self.humanEcho = false
end

-- ───────────────────────────────────────────────────────────────────────
-- Lecture (pure, sans effet de bord)
-- ───────────────────────────────────────────────────────────────────────

-- Rôle affecté à userId pour la manche courante, ou nil hors manche / non affecté.
function RoleManager.getRole(self: RoleManager, userId: number): Types.Role?
	return self.roles[userId]
end

-- userId de l'Écho HUMAIN courant, ou nil si Écho IA / hors manche. Raccourci
-- pratique évitant au Service de scanner les rôles.
function RoleManager.getEchoUserId(self: RoleManager): number?
	return self.echoUserId
end

-- Vrai uniquement si un humain incarne l'Écho cette manche. Le Service s'en sert
-- pour choisir la source d'input de l'EchoController : humain (Remotes) ou IA
-- (EntityAI). false ⇒ Écho IA.
function RoleManager.isHumanEcho(self: RoleManager): boolean
	return self.humanEcho
end

-- Copie défensive de la file de rotation (l'appelant ne doit jamais muter
-- l'ordre interne par référence). Utile au debug / HUD lobby (« prochain Écho »).
function RoleManager.getQueueSnapshot(self: RoleManager): { number }
	return table.clone(self.queue)
end

return RoleManager
