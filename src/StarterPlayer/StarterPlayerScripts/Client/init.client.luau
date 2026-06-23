--!strict
-- init.client — Point d'entrée client : DISPATCHER DE RÔLE (côté survivant + HUD).
--
-- GATE SUR AssignRole : rien de rôle-spécifique ne s'active tant que le serveur
-- n'a pas dit qui on est. À la réception : on (dé)active les controllers SURVIVANT
-- (modules Input/Revive) et on règle la visibilité des boutons (HudController).
--
-- L'Écho, lui, est géré par EchoController.client.luau — un LocalScript AUTONOME
-- (le suffixe .client = LocalScript côté Rojo, non requérable comme module) qui
-- s'auto-gate sur le même AssignRole. init.client ne le pilote donc pas : il se
-- contente de rendre visibles les boutons Écho via HudController.setRole(Echo).
--
-- Robustesse : idempotent sur ré-émission au respawn (même rôle → no-op) ; gère
-- le changement de rôle entre manches (rotation de l'Écho) en désactivant
-- l'ancien set avant d'activer le nouveau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)

local HudController = require(script.HudController)
local InputController = require(script.InputController)
local ReviveController = require(script.ReviveController)
local ProgressionController = require(script.ProgressionController)

-- Rôle courant appliqué (nil = pas encore connu).
local currentRole: Types.Role? = nil

local function onAssignRole(role: unknown)
	-- Défensif : on n'accepte qu'un Role connu.
	if role ~= Types.Role.Survivor and role ~= Types.Role.Echo then
		return
	end
	local newRole = role :: Types.Role
	if newRole == currentRole then
		return -- idempotent (ré-émission au respawn)
	end

	-- Désactive le set survivant si on QUITTE Survivor (l'Écho se gère seul).
	if currentRole == Types.Role.Survivor then
		InputController.deactivate()
		ReviveController.deactivate()
	end

	-- Visibilité des boutons selon le nouveau rôle (couvre survivant ET écho).
	HudController.setRole(newRole)

	-- Active le set survivant si on DEVIENT Survivor.
	if newRole == Types.Role.Survivor then
		InputController.activate()
		ReviveController.activate()
	end

	currentRole = newRole
end

HudController.init()
ProgressionController.init() -- non role-gated : XP/quêtes pour tous

Remotes.AssignRole.OnClientEvent:Connect(onAssignRole)

print("[Signal Lost] Client prêt — en attente d'AssignRole…")
