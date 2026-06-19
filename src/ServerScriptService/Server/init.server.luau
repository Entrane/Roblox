--!strict
-- init.server — Point d'entrée serveur.
-- Requiert et initialise les Services DANS UN ORDRE DÉTERMINISTE.
-- RoundService en premier : c'est la colonne vertébrale temporelle, les
-- futurs Services (FuseService, PlayerService, EntityService) appelleront
-- RoundService.getRoundManager() pour s'y greffer.

local RoundService = require(script.RoundService)

RoundService.init()

print("[Signal Lost] Serveur démarré.")
