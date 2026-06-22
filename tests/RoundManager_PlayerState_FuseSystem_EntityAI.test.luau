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

print(string.format("==================== TEST_Harness : FIN (%d PASS / %d FAIL) ====================", passCount, failCount))
