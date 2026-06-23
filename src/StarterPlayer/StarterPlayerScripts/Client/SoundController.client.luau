--!strict
-- SoundController — LocalScript autonome : joue les sons du jeu.
--   - SoundEvent (serveur)  : sons gameplay (fuse pickup/deposit/unlock, round
--     start/end) — on joue simplement le soundId reçu.
--   - RoundState (client)   : son d'entrée en Starting (non émis côté serveur).
--   - QuestState (client)   : son quand une quête vient d'être complétée.
--   - XpResult (client)     : son à la réception de l'XP de fin.
--
-- ⚠️ soundIds PLACEHOLDER pour l'instant (SoundConfig) : un id invalide ne joue
-- rien et ne plante pas. Remplacer par des rbxassetid:// en Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local SoundConfig = require(ReplicatedStorage.Shared.SoundConfig)

local lastPhase: Types.RoundPhase? = nil
local lastQuestComplete: { [string]: boolean } = {}
local questInitialized = false

-- Joue un son 2D (parenté à SoundService). Défensif : id vide/non-string ignoré ;
-- Debris nettoie l'instance même si l'id est un placeholder (pas de fuite).
local function playSound(soundId: unknown, volume: unknown)
	if type(soundId) ~= "string" or soundId == "" then
		return
	end
	-- Placeholder (pas un vrai asset rbxassetid://) : on ne tente pas de le
	-- charger, sinon Roblox spamme « Failed to load sound ... Temp read failed ».
	if string.sub(soundId, 1, 6) ~= "rbxass" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = if type(volume) == "number" then volume else 0.5
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, 5)
end

-- Son gameplay poussé par le serveur.
Remotes.SoundEvent.OnClientEvent:Connect(function(payload: { soundId: string, volume: number? })
	if type(payload) ~= "table" then
		return
	end
	playSound(payload.soundId, payload.volume)
end)

-- Entrée en Starting → son de décompte (le serveur n'émet rien pour Starting).
Remotes.RoundState.OnClientEvent:Connect(function(state: Types.RoundState)
	if type(state) ~= "table" then
		return
	end
	if state.phase ~= lastPhase then
		if state.phase == Types.RoundPhase.Starting then
			playSound(SoundConfig.ROUND_STARTING)
		end
		lastPhase = state.phase
	end
end)

-- Une quête vient d'être complétée (transition incomplète→complète).
Remotes.QuestState.OnClientEvent:Connect(function(state: Types.QuestState)
	if type(state) ~= "table" or type(state.quests) ~= "table" then
		return
	end
	for _, q in state.quests do
		if questInitialized and q.complete and not lastQuestComplete[q.id] then
			playSound(SoundConfig.QUEST_COMPLETE)
		end
		lastQuestComplete[q.id] = q.complete
	end
	questInitialized = true -- le premier QuestState n'émet rien (état initial)
end)

-- XP de fin de manche reçu.
Remotes.XpResult.OnClientEvent:Connect(function()
	playSound(SoundConfig.XP_GAINED)
end)
