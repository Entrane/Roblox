--!strict
-- GameConfig — Toutes les valeurs réglables du jeu, centralisées et commentées.
--
-- Module PUR : aucune dépendance Roblox (pas de game:GetService, pas d'objet 3D).
-- Que des constantes nommées, regroupées par catégorie.
--
-- Unités : distances et portées en STUDS, vitesses en STUDS/SECONDE, durées en
-- SECONDES, angles en DEGRÉS, stamina/batterie en points abstraits (0..Max).
--
-- ⚠️ À VALIDER DANS STUDIO : toutes les distances et vitesses n'ont de sens
-- qu'avec l'échelle réelle du bunker et la taille des personnages. À revalider
-- dès qu'on a une map et des personnages à l'échelle.
--
-- Les valeurs marquées « ⚠️ PARI » sont des points d'équilibrage à retester en
-- priorité une fois le jeu jouable.

local GameConfig = {}

-- ───────────────────────────────────────────────────────────────────────
-- Player — déplacement de base
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Player = {
	-- Marche volontairement plus lente que le défaut Roblox (16) pour une
	-- ambiance pesante. ⚠️ PARI.
	WalkSpeed = 12, -- studs/s

	-- Voir le bloc « INTENTION DE DESIGN » ci-dessous (couple Sprint/Chase).
	SprintSpeed = 20, -- studs/s ⚠️ PARI (calibré avec Entity.ChaseSpeed)

	MinPlayers = 1, -- nombre minimum de joueurs pour démarrer (1 = test solo)
	MaxPlayers = 4, -- capacité coop max
}

-- ╔═══════════════════════════════════════════════════════════════════════╗
-- ║ INTENTION DE DESIGN — couple Player.SprintSpeed / Entity.ChaseSpeed     ║
-- ╠═══════════════════════════════════════════════════════════════════════╣
-- ║ Choix retenu : « La fuite pure ne doit PAS suffire. Le sprint crée une  ║
-- ║ FENÊTRE COURTE, pas une échappatoire permanente. »                      ║
-- ║                                                                         ║
-- ║ Conséquence sur les chiffres :                                          ║
-- ║  - SprintSpeed (20) > ChaseSpeed (18) : sprinter OUVRE un écart...      ║
-- ║    ...mais seulement ~2 studs/s, et la stamina ne tient que ~4 s        ║
-- ║    (Stamina.Max / Stamina.DrainPerSecond = 100/25). Gain max ~8 studs.  ║
-- ║  - Stamina vidée → retour WalkSpeed (12) < ChaseSpeed (18) : l'entité   ║
-- ║    recolle à 6 studs/s et reprend les ~8 studs en ~1,3 s.               ║
-- ║                                                                         ║
-- ║ => Le sprint sert à GAGNER UN COIN, UNE PORTE, UN ANGLE — pas à semer   ║
-- ║    l'entité en ligne droite. La survie passe par l'environnement (se    ║
-- ║    cacher, casser la ligne de vue), pas par la course.                  ║
-- ║                                                                         ║
-- ║ Tenue des valeurs : cohérentes avec l'intention. Le vrai réglage fin    ║
-- ║ portera sur l'ÉCART (SprintSpeed - ChaseSpeed) et sur la durée de       ║
-- ║ sprint (Stamina) une fois la map jouable. ⚠️ À RETESTER EN PRIORITÉ.    ║
-- ╚═══════════════════════════════════════════════════════════════════════╝

-- ───────────────────────────────────────────────────────────────────────
-- Stamina — endurance, gouverne le sprint
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Stamina = {
	Max = 100, -- points

	-- 100 / 25 = 4 s de sprint plein. ⚠️ PARI (durée de la « fenêtre »).
	DrainPerSecond = 25,

	-- Récup volontairement plus lente que la dépense (100/15 ≈ 6,7 s) pour
	-- créer de la tension après une fuite.
	RegenPerSecond = 15,

	-- Délai après l'arrêt du sprint avant que la stamina remonte.
	RegenDelay = 1.5, -- s

	-- Seuil mini pour (re)lancer un sprint : évite le « sprint clignotant »
	-- quand la stamina est quasi vide (anti-spam).
	MinToStartSprint = 10, -- points
}

-- ───────────────────────────────────────────────────────────────────────
-- Torch — batterie de la torche
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Torch = {
	BatteryMax = 100, -- points

	-- 100 / 2 = 50 s de lumière continue. Ressort de tension central
	-- (rester dans le noir vs se faire repérer). ⚠️ GROS PARI — retester en 1er.
	DrainPerSecond = 2,

	-- Provision pour de futures piles ramassables (la 3D viendra plus tard ;
	-- ici on ne définit que la valeur rendue par un pickup).
	RechargeOnPickup = 40, -- points

	-- Hypothèse : PAS de recharge automatique. Hors pickup, la batterie ne
	-- fait que descendre. ⚠️ À VALIDER DANS STUDIO (comportement attendu).
}

-- ───────────────────────────────────────────────────────────────────────
-- Fuses — fusibles (objectif principal)
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Fuses = {
	-- Cœur de l'objectif : trouver 5 fusibles → générateur → sortie.
	Total = 5,

	-- NB : aucune position ici (les emplacements 3D sont définis dans Studio).
	-- GameConfig ne stocke que le COMPTE CIBLE.
}

-- ───────────────────────────────────────────────────────────────────────
-- Interaction — interactions génériques (ramasser, activer le générateur…)
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Interaction = {
	-- Portée d'interaction. Confort mobile : trop court = frustrant au doigt.
	-- ⚠️ PARI.
	Distance = 8, -- studs

	-- Ramassage instantané pour commencer ; on pourra ajouter un temps de
	-- maintien plus tard si besoin de tension.
	FuseGrabTime = 0, -- s
}

-- ───────────────────────────────────────────────────────────────────────
-- Revive — réanimation d'un coéquipier à terre
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Revive = {
	Duration = 3, -- s — imposé par le cahier des charges.

	-- Plus court que l'interaction normale : il faut être collé au coéquipier.
	Distance = 6, -- studs

	-- Temps qu'un joueur À TERRE met à mourir s'il n'est pas réanimé (Downed → Dead).
	-- Crée la pression temporelle de la réanimation. ⚠️ PARI.
	BleedOutTime = 30, -- s

	-- Fraction de stamina rendue à la réanimation réussie (« groggy » = tension).
	-- 0.5 = moitié de Stamina.Max.
	StaminaOnRevive = 0.5, -- ratio 0..1

	-- Hypothèse : la réanimation s'ANNULE si le réanimateur s'éloigne (> Distance)
	-- ou est lui-même mis à terre. Logique gérée dans PlayerState ; ici, constantes.
	-- ⚠️ À VALIDER DANS STUDIO.
}

-- ───────────────────────────────────────────────────────────────────────
-- Entity — l'IA traqueuse (FSM : patrouille / recherche / poursuite / attaque)
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Entity = {
	-- Plus lente que la marche joueur (12) : en patrouille, on peut l'éviter.
	PatrolSpeed = 8, -- studs/s

	-- Entre WalkSpeed (12) et SprintSpeed (20) du joueur. Voir le bloc
	-- « INTENTION DE DESIGN » ci-dessus. ⚠️ GROS PARI.
	ChaseSpeed = 18, -- studs/s

	-- Détection visuelle.
	SightRange = 40, -- studs
	SightAngle = 90, -- degrés (FOV total, soit ±45° ; elle ne voit pas dans le dos)

	-- Détection au son (sprint/bruit). Le sprint fera plus de bruit que la
	-- marche (modélisé plus tard côté Service). ⚠️ À VALIDER DANS STUDIO.
	HearRange = 25, -- studs

	-- Temps passé en état « recherche » à la dernière position connue avant
	-- d'abandonner et de repartir en patrouille.
	SearchDuration = 8, -- s

	-- Délai sans voir/entendre la cible avant de passer poursuite → recherche.
	LoseTargetTime = 4, -- s

	-- Attaque.
	AttackRange = 4, -- studs
	AttackCooldown = 2, -- s — laisse une fenêtre de fuite / réanimation

	-- Hypothèse : l'attaque MET À TERRE (ne tue pas directement). La mort vient
	-- du cumul / de l'abandon. ⚠️ À CONFIRMER côté PlayerState.
}

-- ───────────────────────────────────────────────────────────────────────
-- Round — phases de manche (FSM : lobby / partie / victoire / défaite)
-- ───────────────────────────────────────────────────────────────────────
GameConfig.Round = {
	LobbyDuration = 15, -- s — attente / regroupement avant départ
	IntermissionDuration = 8, -- s — écran de fin (victoire/défaite) avant retour lobby

	-- Garde-fou : si rien n'aboutit, la manche se termine. ⚠️ PARI.
	MaxRoundDuration = 600, -- s (10 min)
}

-- Table gelée pour éviter toute modification accidentelle à l'exécution.
-- NB : table.freeze est SUPERFICIEL (shallow). On gèle donc aussi chaque
-- sous-table ci-dessous pour protéger réellement toutes les valeurs.
for _, category in pairs(GameConfig) do
	if type(category) == "table" then
		table.freeze(category)
	end
end
table.freeze(GameConfig)

return GameConfig
