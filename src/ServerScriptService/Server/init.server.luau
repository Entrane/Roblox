--!strict
-- init.server — Point d'entrée serveur.
-- Requiert et initialise les Services DANS UN ORDRE DÉTERMINISTE :
--   1. RoundService — colonne vertébrale temporelle (les autres lisent sa phase).
--   2. EchoService — possède le RoleManager et l'expose ; doit s'initialiser
--      AVANT PlayerService, qui (6c) lira EchoService.getRoleManager() pour
--      exclure l'Écho du registre survivant.
--   3. PlayerService — LIT la phase de RoundService et d'EchoService
--      (getRoleManager) ; calcule le vainqueur et ÉCRIT via signalRoundResolved().
-- (FuseService viendra ensuite.)

local RoundService = require(script.RoundService)
local EchoService = require(script.EchoService)
local PlayerService = require(script.PlayerService)

RoundService.init()
EchoService.init()
PlayerService.init()

print("[Signal Lost] Serveur démarré.")
