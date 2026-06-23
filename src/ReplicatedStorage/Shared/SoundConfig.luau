--!strict
-- SoundConfig — Identifiants de sons nommés (constantes partagées serveur/client).
-- Valeurs PLACEHOLDER pour l'instant : à remplacer en Studio par des
-- "rbxassetid://NNNNN" une fois les fichiers audio choisis. Un soundId invalide
-- ne joue rien mais NE PLANTE PAS (SoundController est défensif).
--
-- Pur : aucune dépendance. Gelé pour éviter toute modification à l'exécution.

local SoundConfig = {
	-- Gameplay (émis par le serveur via SoundEvent)
	FUSE_PICKUP = "placeholder_fuse_pickup",
	FUSE_DEPOSIT = "placeholder_fuse_deposit",
	GENERATOR_UNLOCK = "placeholder_generator_unlock",
	ROUND_START = "placeholder_round_start", -- entrée Playing
	ROUND_END = "placeholder_round_end", -- entrée Resolved

	-- Client (joués par SoundController depuis RoundState/QuestState/XpResult)
	ROUND_STARTING = "placeholder_round_starting", -- entrée Starting (décompte)
	QUEST_COMPLETE = "placeholder_quest_complete",
	XP_GAINED = "placeholder_xp_gained",
}

return table.freeze(SoundConfig)
