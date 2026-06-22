-- TEST_Harness — SCRIPT DE TEST TEMPORAIRE. A SUPPRIMER une fois valide.
-- Verifie des cas limites explicites de RoundManager, PlayerState, FuseSystem et EntityAI.
-- Pas de framework : comparaisons manuelles + print PASS/FAIL par scenario.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local RoundManager = require(ServerStorage.Logic.RoundManager)
local PlayerState = require(ServerStorage.Logic.PlayerState)
local FuseSystem = require(ServerStorage.Logic.FuseSystem)
local EntityAI = require(ServerStorage.Logic.EntityAI)
local RoleManager = require(ServerStorage.Logic.RoleManager)
local EchoController = require(ServerStorage.Logic.EchoController)

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

scenario("4. RoundManager - la resolution gagne le timeout (onRoundResolved(Survivors) + dt > MaxRoundDuration meme tick)", function(rep)
	local round = RoundManager.new()
	round:onPlayerJoined(1)
	round:update(0) -- Starting
	round:update(GameConfig.Round.LobbyDuration + 0.1) -- Playing
	round:onRoundResolved(Types.Faction.Survivors)
	round:update(GameConfig.Round.MaxRoundDuration + 100) -- depasse aussi le garde-fou de duree
	local phase = round:getPhase()
	local winner = round:getState().winner
	local ok = phase == Types.RoundPhase.Resolved and winner == Types.Faction.Survivors
	rep(
		string.format("phase=%s, winner=%s", Types.RoundPhase.Resolved, Types.Faction.Survivors),
		string.format("phase=%s, winner=%s", phase, tostring(winner)),
		ok
	)
end)

scenario("5. RoundManager - onRoundResolved() en Lobby est ignore (pas de winner hors Playing)", function(rep)
	local round = RoundManager.new()
	round:onRoundResolved(Types.Faction.Survivors)
	local actualPhase = round:getPhase()
	local actualWinner = round:getState().winner
	local ok = actualPhase == Types.RoundPhase.Lobby and actualWinner == nil
	rep(
		string.format("phase=%s, winner=nil", Types.RoundPhase.Lobby),
		string.format("phase=%s, winner=%s", actualPhase, tostring(actualWinner)),
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

-- ============================================================
-- EntityAI -- scenarios par SEQUENCES de plusieurs update() successifs
-- ============================================================

local function mkObs(userId: number, distance: number, visible: boolean, audible: boolean, lifeState: Types.PlayerLifeState, position: Vector3?): Types.EntityObservation
	return {
		userId = userId,
		distance = distance,
		visible = visible,
		audible = audible,
		lifeState = lifeState,
		position = position or Vector3.new(distance, 0, 0),
	}
end

scenario("18. EntityAI E1 - Patrol -> Chase sur un joueur Alive visible (sequence de 3 ticks)", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 20, true, false, Types.LifeState.Alive) })
	ai:update(0.1, { mkObs(1, 20, true, false, Types.LifeState.Alive) })
	ai:update(0.1, { mkObs(1, 20, true, false, Types.LifeState.Alive) })

	local phase = ai:getPhase()
	local target = ai:getState().targetUserId
	local ok = phase == Types.EntityPhase.Chase and target == 1
	rep(
		string.format("phase=%s, target=1", Types.EntityPhase.Chase),
		string.format("phase=%s, target=%s", phase, tostring(target)),
		ok
	)
end)

scenario("19. EntityAI E2 corrige - audible=true ne retient PAS noContactTimer, Chase -> Search apres 4s cumules", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 10, true, false, Types.LifeState.Alive) }) -- entre en Chase
	local phaseAfterEnter = ai:getPhase()

	-- 3 ticks de 1s sans vue mais AVEC audible=true : ne doit PAS empecher le decompte
	ai:update(1, { mkObs(1, 10, false, true, Types.LifeState.Alive) })
	ai:update(1, { mkObs(1, 10, false, true, Types.LifeState.Alive) })
	ai:update(1, { mkObs(1, 10, false, true, Types.LifeState.Alive) })
	local phaseBeforeThreshold = ai:getPhase() -- noContactTimer=3 < 4, doit rester Chase

	-- 4e tick : noContactTimer atteint LoseTargetTime(4) malgre audible=true
	ai:update(1, { mkObs(1, 10, false, true, Types.LifeState.Alive) })
	local phaseAfterThreshold = ai:getPhase()

	local ok = phaseAfterEnter == Types.EntityPhase.Chase
		and phaseBeforeThreshold == Types.EntityPhase.Chase
		and phaseAfterThreshold == Types.EntityPhase.Search

	rep(
		"apres entree: Chase ; apres 3s audible-only: Chase (noContactTimer=3<4) ; apres 4s: Search",
		string.format("apres entree: %s ; apres 3s: %s ; apres 4s: %s", phaseAfterEnter, phaseBeforeThreshold, phaseAfterThreshold),
		ok
	)
end)

scenario("20. EntityAI E3 - Chase -> Attack, coup cyclique selon AttackCooldown (pas a chaque tick)", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 10, true, false, Types.LifeState.Alive) }) -- Patrol -> Chase (hors de portee)

	ai:update(0.1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- Chase -> Attack (transition, pas de frappe ce tick)
	local phaseAfterAttackEnter = ai:getPhase()

	local hit3 = ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- cooldown pret -> frappe
	local hit4 = ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- cooldown=1 (sur 2) -> pas de frappe
	local hit5 = ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- cooldown=0 -> frappe a nouveau

	local ok = phaseAfterAttackEnter == Types.EntityPhase.Attack
		and hit3 == 1 and hit4 == nil and hit5 == 1

	rep(
		"apres entree Attack: pas de frappe ; +1s: hit=1 ; +1s: hit=nil (cooldown) ; +1s: hit=1 (cooldown ecoule)",
		string.format("phaseAttack=%s ; hit3=%s, hit4=%s, hit5=%s", phaseAfterAttackEnter, tostring(hit3), tostring(hit4), tostring(hit5)),
		ok
	)
end)

scenario("21. EntityAI - achevement a deux coups : cible verrouillee maintenue malgre Downed, Dead -> Patrol direct", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- Patrol -> Chase, deja a portee
	ai:update(0.1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- Chase -> Attack (transition, pas de frappe)

	local hitStrike1 = ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Alive) }) -- cooldown pret -> frappe 1
	-- Le Service aurait appele PlayerState.applyAttack(1) ici : Alive -> Downed (simule ci-dessous).

	local hitNoCooldown = ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Downed) }) -- cooldown pas encore ecoule
	local targetWhileDowned = ai:getState().targetUserId
	local phaseWhileDowned = ai:getPhase()

	local hitStrike2 = ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Downed) }) -- cooldown ecoule -> frappe 2
	-- Le Service aurait appele PlayerState.applyAttack(1) ici : Downed -> Dead (simule ci-dessous).

	ai:update(1, { mkObs(1, 3, true, false, Types.LifeState.Dead) })
	local phaseAfterDeath = ai:getPhase()
	local targetAfterDeath = ai:getState().targetUserId

	local ok = hitStrike1 == 1
		and targetWhileDowned == 1 and phaseWhileDowned == Types.EntityPhase.Attack and hitNoCooldown == nil
		and hitStrike2 == 1
		and phaseAfterDeath == Types.EntityPhase.Patrol and targetAfterDeath == nil

	rep(
		"frappe1=1 ; reste verrouille sur 1 pendant Downed (Attack, pas de re-evaluation) ; frappe2=1 (achevement) ; puis Patrol direct, target=nil",
		string.format(
			"frappe1=%s ; pendant Downed: target=%s phase=%s hit=%s ; frappe2=%s ; apres mort: phase=%s target=%s",
			tostring(hitStrike1), tostring(targetWhileDowned), phaseWhileDowned, tostring(hitNoCooldown),
			tostring(hitStrike2), phaseAfterDeath, tostring(targetAfterDeath)
		),
		ok
	)
end)

scenario("22. EntityAI Partie C - priorite Alive > Downed (dernier recours)", function(rep)
	local ai = EntityAI.new()
	local obs = {
		mkObs(1, 5, true, false, Types.LifeState.Downed), -- proche, Downed
		mkObs(2, 30, true, false, Types.LifeState.Alive), -- loin, Alive
	}
	ai:update(0.1, obs)
	ai:update(0.1, obs)

	local target = ai:getState().targetUserId
	local ok = target == 2

	rep("target=2 (Alive, malgre un Downed plus proche)", string.format("target=%s", tostring(target)), ok)
end)

scenario("23. EntityAI Partie D.2 - pas de re-engagement : cible verrouillee ignore un candidat plus proche", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 20, true, false, Types.LifeState.Alive) }) -- verrouille sur A

	ai:update(0.1, {
		mkObs(1, 20, true, false, Types.LifeState.Alive),
		mkObs(2, 5, true, false, Types.LifeState.Alive), -- B, plus proche, apparait
	})
	ai:update(0.1, {
		mkObs(1, 20, true, false, Types.LifeState.Alive),
		mkObs(2, 5, true, false, Types.LifeState.Alive),
	})

	local target = ai:getState().targetUserId
	local ok = target == 1

	rep("target=1 (A, inchange malgre B plus proche)", string.format("target=%s", tostring(target)), ok)
end)

scenario("24a. EntityAI regle transverse - lifeState Dead -> Patrol direct (jamais Search)", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 20, true, false, Types.LifeState.Alive) }) -- Chase
	ai:update(1, { mkObs(1, 20, true, false, Types.LifeState.Dead) }) -- cible devient Dead

	local phase = ai:getPhase()
	local target = ai:getState().targetUserId
	local ok = phase == Types.EntityPhase.Patrol and target == nil

	rep("phase=Patrol, target=nil", string.format("phase=%s, target=%s", phase, tostring(target)), ok)
end)

scenario("24b. EntityAI regle transverse - cible absente des observations -> Patrol direct (jamais Search)", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 20, true, false, Types.LifeState.Alive) }) -- Chase
	ai:update(1, {}) -- joueur 1 a quitte la partie, absent de la liste

	local phase = ai:getPhase()
	local target = ai:getState().targetUserId
	local ok = phase == Types.EntityPhase.Patrol and target == nil

	rep("phase=Patrol, target=nil", string.format("phase=%s, target=%s", phase, tostring(target)), ok)
end)

scenario("25. EntityAI E5 - Search -> Patrol apres SearchDuration cumule (cible toujours presente, sans contact)", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 10, true, false, Types.LifeState.Alive) }) -- Chase

	-- 4 ticks de 1s sans aucun contact -> Chase -> Search (LoseTargetTime=4)
	for _ = 1, 4 do
		ai:update(1, { mkObs(1, 10, false, false, Types.LifeState.Alive) })
	end
	local phaseEnteredSearch = ai:getPhase()

	-- 7 ticks supplementaires en Search, toujours sans contact (joueur encore present)
	for _ = 1, 7 do
		ai:update(1, { mkObs(1, 10, false, false, Types.LifeState.Alive) })
	end
	local phaseBeforeTimeout = ai:getPhase() -- stateTimer=7 < SearchDuration(8)

	-- 8e tick en Search : SearchDuration atteint
	ai:update(1, { mkObs(1, 10, false, false, Types.LifeState.Alive) })
	local phaseAfterTimeout = ai:getPhase()
	local target = ai:getState().targetUserId
	local lastPos = ai:getState().lastKnownPosition

	local ok = phaseEnteredSearch == Types.EntityPhase.Search
		and phaseBeforeTimeout == Types.EntityPhase.Search
		and phaseAfterTimeout == Types.EntityPhase.Patrol
		and target == nil and lastPos == nil

	rep(
		"entre en Search ; reste Search a 7s ; Patrol a 8s, target=nil, lastKnownPosition=nil",
		string.format("apres perte de vue: %s ; a 7s: %s ; a 8s: %s, target=%s, lastPos=%s",
			phaseEnteredSearch, phaseBeforeTimeout, phaseAfterTimeout, tostring(target), tostring(lastPos)),
		ok
	)
end)

scenario("26. EntityAI E4 - Search -> Chase avec changement de cible (B different de A)", function(rep)
	local ai = EntityAI.new()
	ai:update(0.1, { mkObs(1, 10, true, false, Types.LifeState.Alive) }) -- Chase sur A

	for _ = 1, 4 do
		ai:update(1, { mkObs(1, 10, false, false, Types.LifeState.Alive) })
	end
	local phaseInSearch = ai:getPhase() -- Search

	-- B (different de A) devient visible pendant que A reste present sans contact
	ai:update(1, {
		mkObs(1, 10, false, false, Types.LifeState.Alive),
		mkObs(2, 15, true, false, Types.LifeState.Alive),
	})

	local phase = ai:getPhase()
	local target = ai:getState().targetUserId

	local ok = phaseInSearch == Types.EntityPhase.Search and phase == Types.EntityPhase.Chase and target == 2

	rep(
		"entre en Search sur A ; redetection de B -> Chase, target=2 (pas 1)",
		string.format("phaseSearch=%s ; apres redetection: phase=%s, target=%s", phaseInSearch, phase, tostring(target)),
		ok
	)
end)

-- ============================================================
-- RoleManager
-- ============================================================

scenario("27. RoleManager - rotation round-robin de l'Echo sur plusieurs manches (1->2->3->1)", function(rep)
	local rm = RoleManager.new()
	rm:onPlayerJoined(1)
	rm:onPlayerJoined(2)
	rm:onPlayerJoined(3) -- file = [1,2,3], effectif 3 >= HumanEchoMinPlayers(3)

	local echos = {}
	for _ = 1, 4 do
		rm:assignRoles({ 1, 2, 3 })
		table.insert(echos, rm:getEchoUserId())
		rm:resetRoundAssignment()
	end

	-- Chacun son tour : 1, puis 2, puis 3, puis on reboucle sur 1.
	local ok = echos[1] == 1 and echos[2] == 2 and echos[3] == 3 and echos[4] == 1
	rep(
		"Echos successifs = 1, 2, 3, 1",
		string.format("Echos = %s, %s, %s, %s", tostring(echos[1]), tostring(echos[2]), tostring(echos[3]), tostring(echos[4])),
		ok
	)
end)

scenario("28. RoleManager - doublon dans playerIds dedoublonne (compte reel < seuil -> Echo IA)", function(rep)
	local rm = RoleManager.new()
	rm:onPlayerJoined(1)
	rm:onPlayerJoined(2) -- 2 joueurs reels seulement

	-- playerIds contient un doublon (1 deux fois). Sans dedoublonnage, le compte
	-- paraitrait = 3 et basculerait a tort sur un Echo HUMAIN. Avec dedoublonnage,
	-- compte reel = 2 < HumanEchoMinPlayers(3) -> Echo IA.
	rm:assignRoles({ 1, 1, 2 })

	local humanEcho = rm:isHumanEcho()
	local echoId = rm:getEchoUserId()
	local ok = humanEcho == false and echoId == nil
	rep(
		"isHumanEcho=false, getEchoUserId=nil (doublon ignore, compte reel=2<3)",
		string.format("isHumanEcho=%s, getEchoUserId=%s", tostring(humanEcho), tostring(echoId)),
		ok
	)
end)

scenario("29. RoleManager - tete de file absente sautee + joueur hors file jamais Echo (sans blocage)", function(rep)
	local rm = RoleManager.new()
	rm:onPlayerJoined(1)
	rm:onPlayerJoined(2)
	rm:onPlayerJoined(3)
	rm:onPlayerJoined(4) -- file = [1,2,3,4]

	-- Manche a 3 joueurs presents : 1 (tete de file) est ABSENT, et 99 est present
	-- mais jamais passe par onPlayerJoined (absent de la file).
	rm:assignRoles({ 2, 3, 99 })

	local echoId = rm:getEchoUserId() -- doit sauter 1 (absent) -> premier present en file = 2
	local role99 = rm:getRole(99) -- present mais hors file -> Survivor, jamais Echo
	local role2 = rm:getRole(2)
	local ok = echoId == 2
		and role99 == Types.Role.Survivor
		and role2 == Types.Role.Echo
	rep(
		"getEchoUserId=2 (1 absent saute), getRole(99)=Survivor (hors file), getRole(2)=Echo",
		string.format("getEchoUserId=%s, getRole(99)=%s, getRole(2)=%s", tostring(echoId), tostring(role99), tostring(role2)),
		ok
	)
end)

scenario("30. RoleManager - depart de l'Echo humain : humanEcho->false, echoUserId->nil, retire de la file", function(rep)
	local rm = RoleManager.new()
	rm:onPlayerJoined(1)
	rm:onPlayerJoined(2)
	rm:onPlayerJoined(3)
	rm:assignRoles({ 1, 2, 3 }) -- Echo humain = 1

	local echoBefore = rm:getEchoUserId()

	rm:onPlayerLeft(1) -- l'Echo humain quitte EN COURS de manche

	local echoAfter = rm:getEchoUserId()
	local humanEchoAfter = rm:isHumanEcho()
	local roleAfter = rm:getRole(1)

	-- 1 ne doit plus figurer dans la file de rotation.
	local queue = rm:getQueueSnapshot()
	local stillInQueue = false
	for _, id in queue do
		if id == 1 then
			stillInQueue = true
		end
	end

	local ok = echoBefore == 1
		and echoAfter == nil
		and humanEchoAfter == false
		and roleAfter == nil
		and stillInQueue == false
	rep(
		"avant: echo=1 ; apres depart: echoUserId=nil, isHumanEcho=false, getRole(1)=nil, absent de la file",
		string.format(
			"echoBefore=%s ; echoAfter=%s, isHumanEcho=%s, getRole(1)=%s, encoreDansFile=%s",
			tostring(echoBefore), tostring(echoAfter), tostring(humanEchoAfter), tostring(roleAfter), tostring(stillInQueue)
		),
		ok
	)
end)

-- ============================================================
-- RoundManager -- refonte PvP (etat terminal Resolved + onRoundResolved)
-- ============================================================

-- Helper : amene une instance fraiche jusqu'a Playing (1 joueur suffit, MinPlayers=1).
local function newRoundInPlaying()
	local round = RoundManager.new()
	round:onPlayerJoined(1)
	round:update(0) -- Lobby -> Starting
	round:update(GameConfig.Round.LobbyDuration + 0.1) -- Starting -> Playing
	return round
end

scenario("31. RoundManager - le timeout n'auto-resout PLUS (reste Playing/winner nil), puis Service nomme Echo", function(rep)
	local round = newRoundInPlaying()
	round:update(GameConfig.Round.MaxRoundDuration + 100) -- timer expire SANS onRoundResolved
	local phaseAfterTimeout = round:getPhase()
	local winnerAfterTimeout = round:getState().winner

	-- C'est le Service qui nomme la faction sur timeout : temps ecoule -> Echo.
	round:onRoundResolved(Types.Faction.Echo)
	round:update(0.1) -- applique Playing -> Resolved
	local phaseResolved = round:getPhase()
	local winnerResolved = round:getState().winner

	local ok = phaseAfterTimeout == Types.RoundPhase.Playing and winnerAfterTimeout == nil
		and phaseResolved == Types.RoundPhase.Resolved and winnerResolved == Types.Faction.Echo
	rep(
		"timer expire: Playing/winner=nil ; puis onRoundResolved(Echo): Resolved/winner=Echo",
		string.format("apres timeout: %s/%s ; apres resolution: %s/%s",
			phaseAfterTimeout, tostring(winnerAfterTimeout), phaseResolved, tostring(winnerResolved)),
		ok
	)
end)

scenario("32. RoundManager - Resolved -> Lobby apres IntermissionDuration (ex-T8/T9), winner remis a nil", function(rep)
	local round = newRoundInPlaying()
	round:onRoundResolved(Types.Faction.Echo)
	round:update(0.1) -- Playing -> Resolved
	local phaseResolved = round:getPhase()

	round:update(GameConfig.Round.IntermissionDuration + 0.1) -- intermission ecoulee
	local phaseAfter = round:getPhase()
	local winnerAfter = round:getState().winner

	local ok = phaseResolved == Types.RoundPhase.Resolved
		and phaseAfter == Types.RoundPhase.Lobby and winnerAfter == nil
	rep(
		"Resolved puis Lobby (winner remis a nil)",
		string.format("phaseResolved=%s ; apres intermission: %s, winner=%s", phaseResolved, phaseAfter, tostring(winnerAfter)),
		ok
	)
end)

scenario("33. RoundManager - abandon (playerCount=0) en Playing -> Lobby, jette tout winner (ex-T7)", function(rep)
	local round = newRoundInPlaying()
	round:onRoundResolved(Types.Faction.Survivors) -- winner pose...
	round:onPlayerLeft(1) -- ...mais le dernier joueur quitte le meme tick
	round:update(0.1) -- abandon PRIORITAIRE sur la resolution

	local phase = round:getPhase()
	local winner = round:getState().winner
	local ok = phase == Types.RoundPhase.Lobby and winner == nil
	rep(
		"phase=Lobby, winner=nil (abandon prioritaire, winner jete)",
		string.format("phase=%s, winner=%s", phase, tostring(winner)),
		ok
	)
end)

scenario("34. RoundManager - onRoundResolved idempotent (premier gagne) + faction invalide ignoree", function(rep)
	local round = newRoundInPlaying()
	round:onRoundResolved("Bidon" :: any) -- faction invalide -> ne verrouille rien
	round:onRoundResolved(Types.Faction.Survivors) -- premier valide -> verrouille
	round:onRoundResolved(Types.Faction.Echo) -- deuxieme valide -> ignore
	round:update(0.1) -- applique

	local phase = round:getPhase()
	local winner = round:getState().winner
	-- Si l'invalide avait verrouille, le Survivors suivant serait ignore et le
	-- winner final serait "Bidon" -> l'assertion winner==Survivors prouve le rejet.
	local ok = phase == Types.RoundPhase.Resolved and winner == Types.Faction.Survivors
	rep(
		"Survivors verrouille (invalide rejete, Echo ulterieur ignore)",
		string.format("phase=%s, winner=%s", phase, tostring(winner)),
		ok
	)
end)

-- ============================================================
-- PlayerState -- extension PvP (Escaped + areAllSurvivorsResolved)
-- ============================================================

scenario("35. PlayerState markEscaped - Alive -> Escaped ; Downed/Dead ignores (garde Alive)", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1) -- restera Alive -> Escaped
	ps:registerPlayer(2) -- sera Downed
	ps:registerPlayer(3) -- sera Dead
	ps:applyAttack(2) -- Downed
	ps:applyAttack(3); ps:applyAttack(3) -- Dead

	ps:markEscaped(1) -- Alive -> Escaped
	ps:markEscaped(2) -- Downed -> ignore
	ps:markEscaped(3) -- Dead -> ignore

	local s1 = ps:getState(1)
	local s2 = ps:getState(2)
	local s3 = ps:getState(3)
	local ok = s1 ~= nil and s1.lifeState == Types.LifeState.Escaped
		and s2 ~= nil and s2.lifeState == Types.LifeState.Downed
		and s3 ~= nil and s3.lifeState == Types.LifeState.Dead
	rep(
		"1=Escaped, 2=Downed (inchange), 3=Dead (inchange)",
		string.format("1=%s, 2=%s, 3=%s",
			s1 and s1.lifeState or "nil", s2 and s2.lifeState or "nil", s3 and s3.lifeState or "nil"),
		ok
	)
end)

scenario("36. PlayerState Escaped terminal - applyAttack inerte, setReviving rejete (pas de reanimation d'un evade)", function(rep)
	local ps = PlayerState.new()
	ps:registerPlayer(1) -- evade
	ps:registerPlayer(2) -- sauveteur potentiel (Alive)
	ps:markEscaped(1) -- Alive -> Escaped

	ps:applyAttack(1) -- terminal -> inerte
	local afterAttack = ps:getState(1)

	ps:setReviving(1, 2) -- cible non Downed -> rejete par le garde existant
	local rec = (ps :: any).players[1]

	local ok = afterAttack ~= nil and afterAttack.lifeState == Types.LifeState.Escaped
		and rec.revivingBy == nil and rec.reviveProgress == 0
	rep(
		"reste Escaped apres applyAttack ; revivingBy=nil, reviveProgress=0 (setReviving rejete)",
		string.format("lifeState=%s ; revivingBy=%s, reviveProgress=%s",
			afterAttack and afterAttack.lifeState or "nil", tostring(rec.revivingBy), tostring(rec.reviveProgress)),
		ok
	)
end)

scenario("37. PlayerState areAllSurvivorsResolved + hasAnyEscaped - Dead/Escaped seulement, sinon false", function(rep)
	-- 0 joueur -> false
	local empty = PlayerState.new()
	local r0 = empty:areAllSurvivorsResolved()

	-- un Alive -> false
	local a = PlayerState.new(); a:registerPlayer(1)
	local rAlive = a:areAllSurvivorsResolved()

	-- un Downed reste -> false (non resolu) ; hasAnyEscaped=false
	local d = PlayerState.new(); d:registerPlayer(1); d:applyAttack(1)
	local rDowned = d:areAllSurvivorsResolved()
	local escDowned = d:hasAnyEscaped()

	-- mix Dead + Escaped -> true ; hasAnyEscaped=true
	local mix = PlayerState.new()
	mix:registerPlayer(1); mix:registerPlayer(2)
	mix:applyAttack(1); mix:applyAttack(1) -- 1 Dead
	mix:markEscaped(2) -- 2 Escaped
	local rMix = mix:areAllSurvivorsResolved()
	local escMix = mix:hasAnyEscaped()

	-- tous Escaped -> true
	local esc = PlayerState.new()
	esc:registerPlayer(1); esc:registerPlayer(2)
	esc:markEscaped(1); esc:markEscaped(2)
	local rEsc = esc:areAllSurvivorsResolved()

	local ok = r0 == false and rAlive == false and rDowned == false
		and rMix == true and rEsc == true
		and escDowned == false and escMix == true
	rep(
		"resolved: 0j=false,Alive=false,Downed=false,mix=true,tousEsc=true ; escaped: Downed=false,mix=true",
		string.format("resolved(0j=%s,Alive=%s,Downed=%s,mix=%s,tousEsc=%s) escaped(Downed=%s,mix=%s)",
			tostring(r0), tostring(rAlive), tostring(rDowned), tostring(rMix), tostring(rEsc),
			tostring(escDowned), tostring(escMix)),
		ok
	)
end)

scenario("38. PlayerState course Alive/attaque - fuite d'abord gagne ; attaque d'abord gagne (les deux ordres surs)", function(rep)
	-- Ordre 1 : markEscaped AVANT applyAttack -> Escaped, attaque inerte
	local a = PlayerState.new(); a:registerPlayer(1)
	a:markEscaped(1); a:applyAttack(1)
	local s1 = a:getState(1)

	-- Ordre 2 : applyAttack AVANT markEscaped -> Downed, fuite rejetee
	local b = PlayerState.new(); b:registerPlayer(1)
	b:applyAttack(1); b:markEscaped(1)
	local s2 = b:getState(1)

	local ok = s1 ~= nil and s1.lifeState == Types.LifeState.Escaped
		and s2 ~= nil and s2.lifeState == Types.LifeState.Downed
	rep(
		"fuite d'abord=Escaped ; attaque d'abord=Downed",
		string.format("ordre1=%s ; ordre2=%s", s1 and s1.lifeState or "nil", s2 and s2.lifeState or "nil"),
		ok
	)
end)

-- ============================================================
-- EchoController -- capacités Écho (écholocation pulsée + Howl + Frenzy)
-- ============================================================

local ECHO = GameConfig.Echo

-- Construit une EntityObservation minimale pour l'écholocation (position fournie
-- par défaut, comme la politique de remplissage du Service dans la portée).
local function mkEchoObs(userId: number, distance: number, lifeState: Types.PlayerLifeState, position: Vector3?): Types.EntityObservation
	return {
		userId = userId,
		distance = distance,
		visible = false, -- l'écholocation ne dépend PAS de la vue (sonar)
		audible = false,
		lifeState = lifeState,
		position = position or Vector3.new(distance, 0, 0),
	}
end

scenario("39. EchoController requestAbility - Howl active (effet+cooldown), re-trigger pendant actif rejete, id invalide ignore", function(rep)
	local echo = EchoController.new()
	echo:requestAbility(Types.AbilityId.Howl)
	local s1 = echo:getState()

	-- Re-trigger immediat : cooldown > 0 -> rejete, aucun reset des timers.
	echo:requestAbility(Types.AbilityId.Howl)
	local s2 = echo:getState()

	-- Id invalide : aucun effet (ni Howl ni Frenzy ne bougent).
	echo:requestAbility("Bidon" :: any)
	local s3 = echo:getState()

	local ok = s1.howl.activeRemaining == ECHO.Howl.RevealDuration and s1.howl.cooldownRemaining == ECHO.Howl.Cooldown
		and s2.howl.activeRemaining == ECHO.Howl.RevealDuration and s2.howl.cooldownRemaining == ECHO.Howl.Cooldown
		and s3.frenzy.activeRemaining == 0 and s3.frenzy.cooldownRemaining == 0
	rep(
		string.format("Howl active=%d/cd=%d, re-trigger inchange, id invalide sans effet", ECHO.Howl.RevealDuration, ECHO.Howl.Cooldown),
		string.format("s1(act=%s,cd=%s) s2(act=%s,cd=%s) frenzy(act=%s,cd=%s)",
			tostring(s1.howl.activeRemaining), tostring(s1.howl.cooldownRemaining),
			tostring(s2.howl.activeRemaining), tostring(s2.howl.cooldownRemaining),
			tostring(s3.frenzy.activeRemaining), tostring(s3.frenzy.cooldownRemaining)),
		ok
	)
end)

scenario("40. EchoController - Howl et Frenzy independantes, coexistent (vitesse boostee + revelation totale)", function(rep)
	local echo = EchoController.new()
	echo:requestAbility(Types.AbilityId.Frenzy)
	echo:requestAbility(Types.AbilityId.Howl) -- pendant que Frenzy est active

	local s = echo:getState()
	local bothActive = s.frenzy.activeRemaining > 0 and s.howl.activeRemaining > 0
	local speed = echo:getMoveSpeed() -- Frenzy actif -> boostee

	-- Howl actif -> un survivant HORS portee est quand meme pingue (revelation totale).
	local farObs = { mkEchoObs(1, ECHO.EcholocationRange + 100, Types.LifeState.Alive) }
	local pings = echo:update(ECHO.EcholocationInterval, farObs) -- 1er pulse

	local ok = bothActive
		and math.abs(speed - ECHO.MoveSpeed * ECHO.Frenzy.SpeedMultiplier) < 1e-6
		and pings ~= nil and #pings == 1 and pings[1].userId == 1
	rep(
		string.format("les deux actives, speed=%.1f, survivant hors portee pingue (Howl)", ECHO.MoveSpeed * ECHO.Frenzy.SpeedMultiplier),
		string.format("bothActive=%s speed=%s pings=%s", tostring(bothActive), tostring(speed), pings and tostring(#pings) or "nil"),
		ok
	)
end)

scenario("41. EchoController ecolocation pulsee - rien avant l'intervalle, emission au pulse, filtres portee/etat/position", function(rep)
	local echo = EchoController.new()

	local obs = {
		mkEchoObs(1, 10, Types.LifeState.Alive), -- proche, vivant -> pingue
		mkEchoObs(2, ECHO.EcholocationRange + 50, Types.LifeState.Alive), -- hors portee -> NON
		mkEchoObs(3, 5, Types.LifeState.Downed), -- proche, a terre -> pingue
		mkEchoObs(4, 5, Types.LifeState.Dead), -- proche mais Dead -> NON
		mkEchoObs(5, 5, Types.LifeState.Escaped), -- proche mais Escaped -> NON
		{ userId = 6, distance = 5, visible = false, audible = false, lifeState = Types.LifeState.Alive, position = nil }, -- position nil -> skip defensif
	}

	-- Avant l'intervalle : pas d'emission.
	local before = echo:update(ECHO.EcholocationInterval - 0.1, obs)
	-- Cumul atteint l'intervalle : emission.
	local atPulse = echo:update(0.1, obs)

	local ids = {}
	if atPulse then
		for _, p in atPulse do ids[p.userId] = true end
	end
	local ok = before == nil
		and atPulse ~= nil and #atPulse == 2 and ids[1] and ids[3]
		and not ids[2] and not ids[4] and not ids[5] and not ids[6]
	rep(
		"avant intervalle=nil ; au pulse: {1,3} seulement (2 hors portee, 4 Dead, 5 Escaped, 6 sans position)",
		string.format("before=%s ; pulse count=%s ids={1=%s,2=%s,3=%s,4=%s,5=%s,6=%s}",
			tostring(before), atPulse and tostring(#atPulse) or "nil",
			tostring(ids[1]), tostring(ids[2]), tostring(ids[3]), tostring(ids[4]), tostring(ids[5]), tostring(ids[6])),
		ok
	)
end)

scenario("42. EchoController - effets expirent puis re-declenchables ; vitesse revient a la base", function(rep)
	local echo = EchoController.new()
	echo:requestAbility(Types.AbilityId.Frenzy)
	local speedDuring = echo:getMoveSpeed() -- boostee

	-- Laisse l'effet Frenzy expirer (Duration) sans atteindre le cooldown complet.
	echo:update(ECHO.Frenzy.Duration + 0.01, {})
	local sAfterEffect = echo:getState()
	local speedAfter = echo:getMoveSpeed() -- retour base

	-- Re-trigger pendant que le cooldown court encore -> rejete.
	echo:requestAbility(Types.AbilityId.Frenzy)
	local sStillCd = echo:getState()

	-- Laisse le reste du cooldown s'ecouler -> re-declenchable.
	echo:update(ECHO.Frenzy.Cooldown, {})
	echo:requestAbility(Types.AbilityId.Frenzy)
	local sReArmed = echo:getState()

	local ok = math.abs(speedDuring - ECHO.MoveSpeed * ECHO.Frenzy.SpeedMultiplier) < 1e-6
		and sAfterEffect.frenzy.activeRemaining == 0 and sAfterEffect.frenzy.cooldownRemaining > 0
		and math.abs(speedAfter - ECHO.MoveSpeed) < 1e-6
		and sStillCd.frenzy.activeRemaining == 0 -- re-trigger pendant cooldown a echoue
		and sReArmed.frenzy.activeRemaining == ECHO.Frenzy.Duration -- re-declenche apres cooldown
	rep(
		"boostee pendant, base apres expiration, re-trigger en cooldown rejete, re-declenchable apres cooldown",
		string.format("during=%s after=%s actAfter=%s cdAfter=%s stillCdAct=%s reArmedAct=%s",
			tostring(speedDuring), tostring(speedAfter), tostring(sAfterEffect.frenzy.activeRemaining),
			tostring(sAfterEffect.frenzy.cooldownRemaining), tostring(sStillCd.frenzy.activeRemaining),
			tostring(sReArmed.frenzy.activeRemaining)),
		ok
	)
end)

scenario("43. EchoController defensif - update(dt invalide / observations nil) ne plante pas", function(rep)
	local echo = EchoController.new()
	local r1, r2, r3
	local ok = pcall(function()
		r1 = echo:update(-1, {}) -- dt invalide -> traite comme 0, pas de pulse
		r2 = echo:update(ECHO.EcholocationInterval, nil :: any) -- observations nil -> liste vide
		r3 = echo:getMoveSpeed()
	end)
	-- r2 doit etre une liste vide (pulse atteint mais aucune observation).
	local ok2 = ok and r1 == nil and type(r2) == "table" and #r2 == 0 and r3 == ECHO.MoveSpeed
	rep(
		"aucun crash ; dt invalide=nil, obs nil=liste vide, vitesse de base",
		string.format("pcall=%s r1=%s r2=%s r3=%s", tostring(ok), tostring(r1), r2 and ("#"..tostring(#r2)) or tostring(r2), tostring(r3)),
		ok2
	)
end)

print(string.format("==================== TEST_Harness : FIN (%d PASS / %d FAIL) ====================", passCount, failCount))
