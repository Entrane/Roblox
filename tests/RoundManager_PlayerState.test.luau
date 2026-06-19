-- TEST_Harness — SCRIPT DE TEST TEMPORAIRE. A SUPPRIMER une fois valide.
-- Verifie des cas limites explicites de RoundManager et PlayerState.
-- Pas de framework : comparaisons manuelles + print PASS/FAIL par scenario.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local RoundManager = require(ServerStorage.Logic.RoundManager)
local PlayerState = require(ServerStorage.Logic.PlayerState)

local passCount = 0
local failCount = 0

-- Execute un scenario isole. fn recoit `rep(expected, actual, ok)` a appeler
-- pour enregistrer le resultat. Une erreur Lua inattendue (crash) est captee
-- et comptee comme FAIL au lieu d'interrompre les scenarios suivants.
local function scenario(name: string, fn: ((string, string, boolean) -> ()) -> ())
	local function rep(expected: string, actual: string, ok: boolean)
		if ok then
			passCount += 1
		else
			failCount += 1
		end
		local status = if ok then "PASS" else "FAIL"
		print(string.format("[%s] %s || attendu: %s || obtenu: %s", status, name, expected, actual))
	end

	local ok, err = pcall(fn, rep)
	if not ok then
		failCount += 1
		print(string.format("[FAIL] %s || ERREUR INATTENDUE (crash) : %s", name, tostring(err)))
	end
end

print("==================== TEST_Harness : DEBUT ====================")

-- ============================================================
-- RoundManager
-- ============================================================

scenario("1. RoundManager T1 - onPlayerJoined atteint MinPlayers -> Starting", function(rep)
	local round = RoundManager.new()
	round:onPlayerJoined(1)
	round:update(0)
	local actual = round:getPhase()
	rep(Types.RoundPhase.Starting, actual, actual == Types.RoundPhase.Starting)
end)

scenario("2. RoundManager T2 - onPlayerLeft sous MinPlayers pendant Starting -> Lobby (decompte annule)", function(rep)
	local round = RoundManager.new()
	round:onPlayerJoined(1)
	round:update(0) -- Starting
	round:onPlayerLeft(1)
	round:update(0) -- doit revenir en Lobby
	local actualPhase = round:getPhase()
	local actualTimer = round:getState().timeRemaining
	local ok = actualPhase == Types.RoundPhase.Lobby and actualTimer == GameConfig.Round.LobbyDuration
	rep(
		string.format("phase=%s, timeRemaining=%d", Types.RoundPhase.Lobby, GameConfig.Round.LobbyDuration),
		string.format("phase=%s, timeRemaining=%s", actualPhase, tostring(actualTimer)),
		ok
	)
end)

scenario("3. RoundManager T3 - update(dt) > LobbyDuration pendant Starting -> Playing", function(rep)
	local round = RoundManager.new()
	round:onPlayerJoined(1)
	round:update(0) -- Starting
	round:update(GameConfig.Round.LobbyDuration + 0.1)
	local actual = round:getPhase()
	rep(Types.RoundPhase.Playing, actual, actual == Types.RoundPhase.Playing)
end)

scenario("4. RoundManager cas d - victoire gagne le timeout (objectiveComplete + dt > MaxRoundDuration meme tick)", function(rep)
	local round = RoundManager.new()
	round:onPlayerJoined(1)
	round:update(0) -- Starting
	round:update(GameConfig.Round.LobbyDuration + 0.1) -- Playing
	round:onObjectiveComplete()
	round:update(GameConfig.Round.MaxRoundDuration + 100) -- depasse aussi le garde-fou de duree
	local actual = round:getPhase()
	rep(Types.RoundPhase.Victory, actual, actual == Types.RoundPhase.Victory)
end)

scenario("5. RoundManager - onObjectiveComplete() en Lobby est ignore", function(rep)
	local round = RoundManager.new()
	round:onObjectiveComplete()
	local actualPhase = round:getPhase()
	local actualFlag = (round :: any).objectiveComplete
	local ok = actualPhase == Types.RoundPhase.Lobby and actualFlag == false
	rep(
		string.format("phase=%s, objectiveComplete=false", Types.RoundPhase.Lobby),
		string.format("phase=%s, objectiveComplete=%s", actualPhase, tostring(actualFlag)),
		ok
	)
end)

-- ============================================================
-- PlayerState
-- ============================================================

scenario("6. PlayerState cas a - course reanimation/saignement : revive gagne au tick critique", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1) -- cible
	ps:registerPlayer(2) -- sauveteur
	ps:applyAttack(1) -- Alive -> Downed

	local rec = (ps :: any).players[1]
	rec.revivingBy = 2
	rec.bleedOutTimer = GameConfig.Revive.BleedOutTime - 0.05 -- a 0.05s d'expirer
	rec.reviveProgress = GameConfig.Revive.Duration - 0.05 -- a 0.05s de se terminer

	ps:update(0.05) -- meme tick : les deux echeances tombent ensemble

	local state = ps:getState(1)
	local actual = state and state.lifeState or "nil"
	rep(Types.LifeState.Alive, actual, actual == Types.LifeState.Alive)
end)

scenario("7. PlayerState cas b - deux sauveteurs : le premier arrive garde la main", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1) -- cible
	ps:registerPlayer(2) -- sauveteur A
	ps:registerPlayer(3) -- sauveteur B
	ps:applyAttack(1) -- Downed

	ps:setReviving(1, 2) -- A prend la main
	ps:update(0.5) -- progression partielle
	local progressBefore = (ps :: any).players[1].reviveProgress

	ps:setReviving(1, 3) -- B tente de prendre la main -> doit etre ignore
	local rec = (ps :: any).players[1]
	local ok = rec.revivingBy == 2 and rec.reviveProgress == progressBefore
	rep(
		string.format("revivingBy=2, reviveProgress=%s (inchange)", tostring(progressBefore)),
		string.format("revivingBy=%s, reviveProgress=%s", tostring(rec.revivingBy), tostring(rec.reviveProgress)),
		ok
	)
end)

scenario("8. PlayerState cas c - sauveteur retire en pleine reanimation : reset propre sans crash", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1) -- cible
	ps:registerPlayer(2) -- sauveteur
	ps:applyAttack(1) -- Downed

	ps:setReviving(1, 2)
	ps:update(0.5) -- progression accumulee

	ps:removePlayer(2) -- sauveteur retire en pleine reanimation
	ps:update(0.1) -- doit detecter l'absence et reset proprement

	local rec = (ps :: any).players[1]
	local ok = rec.reviveProgress == 0 and rec.revivingBy == nil and rec.lifeState == Types.LifeState.Downed
	rep(
		"reviveProgress=0, revivingBy=nil, lifeState=Downed",
		string.format("reviveProgress=%s, revivingBy=%s, lifeState=%s", tostring(rec.reviveProgress), tostring(rec.revivingBy), rec.lifeState),
		ok
	)
end)

scenario("9a. PlayerState areAllIncapacitated() - aucun joueur -> false", function(rep)
	local ps = PlayerState.new()
	local actual = ps:areAllIncapacitated()
	rep("false", tostring(actual), actual == false)
end)

scenario("9b. PlayerState areAllIncapacitated() - tous Downed/Dead -> true", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1)
	ps:registerPlayer(2)
	ps:applyAttack(1) -- Downed
	ps:applyAttack(2) -- Downed
	ps:applyAttack(2) -- Dead
	local actual = ps:areAllIncapacitated()
	rep("true", tostring(actual), actual == true)
end)

scenario("9c. PlayerState areAllIncapacitated() - au moins un Alive -> false", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1)
	ps:registerPlayer(2)
	ps:applyAttack(1) -- Downed, player 2 reste Alive
	local actual = ps:areAllIncapacitated()
	rep("false", tostring(actual), actual == false)
end)

print(string.format("==================== TEST_Harness : FIN (%d PASS / %d FAIL) ====================", passCount, failCount))
