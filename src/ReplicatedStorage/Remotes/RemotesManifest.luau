--!strict
-- RemotesManifest — Création et accès centralisés des RemoteEvents.
-- Requis des DEUX côtés : le SERVEUR crée les RemoteEvents s'ils manquent, le
-- CLIENT les attend (WaitForChild). Un seul endroit déclare le contrat réseau,
-- et le WaitForChild côté client absorbe la course serveur/client.
--
-- ─── AUTORITÉ SERVEUR ───────────────────────────────────────────────────
-- Tous ces Remotes sont client→serveur. Le serveur (PlayerService) n'utilise
-- QUE le Player fourni par OnServerEvent pour l'IDENTITÉ ; aucun userId reçu du
-- client n'est cru comme identité (voir PlayerService pour le détail).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- script.Parent = dossier ReplicatedStorage.Remotes (ce module en est l'enfant).
local container = script.Parent
local IS_SERVER = RunService:IsServer()

-- Noms canoniques des RemoteEvents client→serveur déclarés à ce stade.
-- (La réplication serveur→client pour le HUD viendra avec la tâche HUD.)
local EVENT_NAMES = {
	"SetSprinting", -- (wants: boolean)
	"SetTorch", -- (on: boolean)
	"SetReviving", -- (targetUserId: number) — cible DONNÉE, revalidée serveur
	"StopReviving", -- () — le sauveteur relâche
}

-- Trouve le RemoteEvent ; le crée côté serveur, l'attend côté client.
local function ensureEvent(name: string): RemoteEvent
	local existing = container:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), `Remotes.{name} existe mais n'est pas un RemoteEvent`)
		return existing
	end
	if IS_SERVER then
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = container
		return event
	end
	return container:WaitForChild(name) :: RemoteEvent
end

export type Remotes = {
	SetSprinting: RemoteEvent,
	SetTorch: RemoteEvent,
	SetReviving: RemoteEvent,
	StopReviving: RemoteEvent,
}

local Remotes = {} :: Remotes
for _, name in EVENT_NAMES do
	(Remotes :: any)[name] = ensureEvent(name)
end

return Remotes
