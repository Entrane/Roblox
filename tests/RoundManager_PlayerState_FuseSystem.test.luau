-- TEST_Harness — SCRIPT DE TEST TEMPORAIRE. A SUPPRIMER une fois valide.
-- Verifie des cas limites explicites de RoundManager, PlayerState et FuseSystem.
-- Pas de framework : comparaisons manuelles + print PASS/FAIL par scenario.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local RoundManager = require(ServerStorage.Logic.RoundManager)
local PlayerState = require(ServerStorage.Logic.PlayerState)
local FuseSystem = require(ServerStorage.Logic.FuseSystem)

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

-- ============================================================
-- FuseSystem
-- ============================================================

scenario("10. FuseSystem T1 - pickup sur Hidden -> Carried, carriedBy correct", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	local pickupOk = fs:pickup(1, 100)
	local fuse1 = fs:getState(1)
	local ok = pickupOk == true and fuse1 ~= nil and fuse1.state == Types.FuseLifeState.Carried and fuse1.carriedBy == 100
	rep(
		"pickup=true, state=Carried, carriedBy=100",
		string.format("pickup=%s, state=%s, carriedBy=%s", tostring(pickupOk), fuse1 and fuse1.state or "nil", tostring(fuse1 and fuse1.carriedBy)),
		ok
	)
end)

scenario("11. FuseSystem cas a/b - pickup sur Carried (autre) et sur Deposited echouent, aucun changement", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	fs:registerFuse(2)

	fs:pickup(1, 100) -- fuse1 Carried par 100
	local pickupOnCarried = fs:pickup(1, 200) -- cas a : deja Carried par un autre
	local fuse1 = fs:getState(1)

	fs:pickup(2, 300)
	fs:deposit(2, 300) -- fuse2 Deposited
	local pickupOnDeposited = fs:pickup(2, 400) -- cas b : deja Deposited
	local fuse2 = fs:getState(2)

	local ok = pickupOnCarried == false
		and fuse1.state == Types.FuseLifeState.Carried and fuse1.carriedBy == 100
		and pickupOnDeposited == false
		and fuse2.state == Types.FuseLifeState.Deposited and fuse2.carriedBy == nil

	rep(
		"pickupOnCarried=false (fuse1 inchange: Carried/100) ; pickupOnDeposited=false (fuse2 inchange: Deposited/nil)",
		string.format(
			"pickupOnCarried=%s (fuse1=%s/%s) ; pickupOnDeposited=%s (fuse2=%s/%s)",
			tostring(pickupOnCarried), fuse1.state, tostring(fuse1.carriedBy),
			tostring(pickupOnDeposited), fuse2.state, tostring(fuse2.carriedBy)
		),
		ok
	)
end)

scenario("12. FuseSystem regle (l) - un joueur porte deja un fusible, pickup sur un 2e echoue", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	fs:registerFuse(2)
	fs:pickup(1, 100) -- 100 porte deja fuse1
	local pickupSecond = fs:pickup(2, 100) -- meme joueur tente fuse2 -> doit echouer
	local fuse2 = fs:getState(2)
	local ok = pickupSecond == false and fuse2.state == Types.FuseLifeState.Hidden and fuse2.carriedBy == nil
	rep(
		"pickup(2,100)=false, fuse2 reste Hidden/carriedBy=nil",
		string.format("pickup(2,100)=%s, fuse2=%s/%s", tostring(pickupSecond), fuse2.state, tostring(fuse2.carriedBy)),
		ok
	)
end)

scenario("13. FuseSystem T2 - deposit par le porteur reussit ; deposit par un usurpateur sur Carried echoue (cas e)", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	fs:registerFuse(2)

	fs:pickup(1, 100)
	local depositOk = fs:deposit(1, 100) -- T2 : le porteur reel depose
	local fuse1 = fs:getState(1)

	fs:pickup(2, 200) -- fuse2 Carried par 200
	local depositByImpostor = fs:deposit(2, 300) -- 300 n'est pas le porteur -> doit echouer
	local fuse2 = fs:getState(2)

	local ok = depositOk == true and fuse1.state == Types.FuseLifeState.Deposited and fuse1.carriedBy == nil
		and depositByImpostor == false and fuse2.state == Types.FuseLifeState.Carried and fuse2.carriedBy == 200

	rep(
		"fuse1: Deposited/nil (depositOk=true) ; fuse2: Carried/200 inchange (depositByImpostor=false)",
		string.format(
			"fuse1=%s/%s (depositOk=%s) ; fuse2=%s/%s (depositByImpostor=%s)",
			fuse1.state, tostring(fuse1.carriedBy), tostring(depositOk),
			fuse2.state, tostring(fuse2.carriedBy), tostring(depositByImpostor)
		),
		ok
	)
end)

scenario("14. FuseSystem T3 - releaseCarriedBy() repasse Hidden ; no-op si userId ne porte rien", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	fs:pickup(1, 100)
	fs:releaseCarriedBy(100)
	local fuse1 = fs:getState(1)

	fs:releaseCarriedBy(999) -- userId qui ne porte rien -> no-op, ne doit pas planter
	local fuse1Again = fs:getState(1)

	local ok = fuse1.state == Types.FuseLifeState.Hidden and fuse1.carriedBy == nil
		and fuse1Again.state == Types.FuseLifeState.Hidden and fuse1Again.carriedBy == nil

	rep(
		"apres release(100): Hidden/nil ; apres releaseCarriedBy(999) no-op: toujours Hidden/nil",
		string.format("apres release(100)=%s/%s ; apres releaseCarriedBy(999)=%s/%s", fuse1.state, tostring(fuse1.carriedBy), fuse1Again.state, tostring(fuse1Again.carriedBy)),
		ok
	)
end)

scenario("15. FuseSystem getProgress() - 0/5 avant depot, 1/5 apres un depot", function(rep)
	local fs = FuseSystem.new()
	for i = 1, GameConfig.Fuses.Total do
		fs:registerFuse(i)
	end

	local before = fs:getProgress()

	fs:pickup(1, 100)
	fs:deposit(1, 100)

	local after = fs:getProgress()

	local ok = before.collected == 0 and before.required == GameConfig.Fuses.Total
		and after.collected == 1 and after.required == GameConfig.Fuses.Total

	rep(
		string.format("avant: collected=0/required=%d ; apres: collected=1/required=%d", GameConfig.Fuses.Total, GameConfig.Fuses.Total),
		string.format("avant: collected=%d/required=%d ; apres: collected=%d/required=%d", before.collected, before.required, after.collected, after.required),
		ok
	)
end)

scenario("16. FuseSystem resetRound() - tous les fusibles repassent Hidden, carriedBy nil", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	fs:registerFuse(2)
	fs:registerFuse(3)

	fs:pickup(1, 100) -- fuse1 reste Carried
	fs:pickup(2, 200)
	fs:deposit(2, 200) -- fuse2 Deposited
	-- fuse3 reste Hidden, jamais touche

	fs:resetRound()

	local all = fs:getAllStates()
	local ok = true
	for _, fuse in all do
		if fuse.state ~= Types.FuseLifeState.Hidden or fuse.carriedBy ~= nil then
			ok = false
		end
	end

	rep(
		"tous les fusibles: state=Hidden, carriedBy=nil",
		string.format(
			"fuse1=%s/%s, fuse2=%s/%s, fuse3=%s/%s",
			all[1].state, tostring(all[1].carriedBy),
			all[2].state, tostring(all[2].carriedBy),
			all[3].state, tostring(all[3].carriedBy)
		),
		ok
	)
end)

scenario("17. FuseSystem registerFuse() idempotent - n'ecrase pas un etat deja Carried", function(rep)
	local fs = FuseSystem.new()
	fs:registerFuse(1)
	fs:pickup(1, 100) -- fuse1 devient Carried par 100

	fs:registerFuse(1) -- second appel, meme id, APRES le pickup -> ne doit rien reecraser

	local fuse1 = fs:getState(1)
	local ok = fuse1.state == Types.FuseLifeState.Carried and fuse1.carriedBy == 100

	rep(
		"state=Carried, carriedBy=100 (inchange malgre le second registerFuse)",
		string.format("state=%s, carriedBy=%s", fuse1.state, tostring(fuse1.carriedBy)),
		ok
	)
end)

print(string.format("==================== TEST_Harness : FIN (%d PASS / %d FAIL) ====================", passCount, failCount))
