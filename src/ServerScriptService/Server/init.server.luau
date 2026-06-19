--!strict
-- init.server — Point d'entrée serveur.
-- Requiert et initialise les Services DANS UN ORDRE DÉTERMINISTE.
-- RoundService en premier : c'est la colonne vertébrale temporelle. PlayerService
-- ensuite : il LIT la phase de RoundService (reset à l'entrée Playing) et ÉCRIT
-- via signalAllPlayersDowned(), donc RoundService doit être initialisé avant.
-- (FuseService, EntityService viendront ensuite.)

local RoundService = require(script.RoundService)
local PlayerService = require(script.PlayerService)

RoundService.init()
PlayerService.init()

print("[Signal Lost] Serveur démarré.")
