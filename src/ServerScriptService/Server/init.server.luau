--!strict
-- init.server — Point d'entrée serveur.
-- Requiert et initialise les Services DANS UN ORDRE DÉTERMINISTE :
--   1. RoundService — colonne vertébrale temporelle (les autres lisent sa phase).
--   2. EchoService — possède le RoleManager et l'expose ; doit s'initialiser
--      AVANT PlayerService, qui (6c) lira EchoService.getRoleManager() pour
--      exclure l'Écho du registre survivant.
--   3. PlayerService — LIT la phase de RoundService et d'EchoService
--      (getRoleManager) ; calcule le vainqueur et ÉCRIT via signalRoundResolved().
--   4. FuseService — LIT l'état des porteurs (PlayerService) et appelle
--      markEscaped ; doit donc s'initialiser APRÈS PlayerService.
--   5. ProgressionService — LIT les compteurs de manche (PlayerService/FuseService)
--      et le rôle (EchoService) au Resolved ; s'initialise en DERNIER.

local RoundService = require(script.RoundService)
local EchoService = require(script.EchoService)
local PlayerService = require(script.PlayerService)
local FuseService = require(script.FuseService)
local ProgressionService = require(script.ProgressionService)

RoundService.init()
EchoService.init()
PlayerService.init()
FuseService.init()
ProgressionService.init()

print("[Signal Lost] Serveur démarré.")
