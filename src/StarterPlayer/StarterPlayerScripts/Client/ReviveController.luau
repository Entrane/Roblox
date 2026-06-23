--!strict
-- ReviveController — Réanimation SURVIVANT. Module piloté par init.client.
--
-- Détecte un coéquipier À TERRE proche via Humanoid.PlatformStand (posé par le
-- serveur pour un Downed, et RÉPLIQUÉ au client) + la portée GameConfig.Revive.
-- Distance (lue côté client). Affiche le bouton contextuel "Réanimer", et envoie
-- SetReviving(cible)/StopReviving (maintien). Le SERVEUR revalide TOUT (cible
-- réellement Downed + portée monde, chaque tick) : la détection client n'est
-- qu'un déclencheur d'UI/intention, jamais une autorité.
--
-- ⚠️ La progression (3 s) n'est pas répliquée au client : pas de barre ; le
-- coéquipier qui se relève est le feedback (suffisant pour le MVP).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local HudController = require(script.Parent.HudController)

local ReviveController = {}

local REVIVE_ACTION = "SL_Revive"
local SCAN_INTERVAL = 0.3 -- s — pas besoin de scanner à 60 Hz

local localPlayer = Players.LocalPlayer

local active = false
local currentTarget: number? = nil -- userId de la cible affichée, ou nil
local reviving = false
local scanAccum = 0
-- { any } : RBXScriptConnection inconnu hors Studio (cf. InputController).
local connections: { any } = {}

local function getHRP(character: Instance?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Coéquipier à terre le plus proche EN PORTÉE, ou nil. « À terre » = Humanoid
-- vivant (Health > 0) avec PlatformStand (signal Downed répliqué).
local function findTarget(): number?
	local myHRP = getHRP(localPlayer.Character)
	if not myHRP then
		return nil
	end

	local best: number? = nil
	local bestDist = GameConfig.Revive.Distance
	for _, other in Players:GetPlayers() do
		if other ~= localPlayer and other.Character then
			local humanoid = other.Character:FindFirstChildOfClass("Humanoid")
			local hrp = getHRP(other.Character)
			if humanoid and hrp and humanoid.Health > 0 and humanoid.PlatformStand then
				local d = (hrp.Position - myHRP.Position).Magnitude
				if d <= bestDist then
					best = other.UserId
					bestDist = d
				end
			end
		end
	end
	return best
end

local function startReviving()
	if currentTarget then
		reviving = true
		Remotes.SetReviving:FireServer(currentTarget)
	end
end

local function stopReviving()
	if reviving then
		reviving = false
		Remotes.StopReviving:FireServer()
	end
end

local function onReviveKey(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		startReviving()
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		stopReviving()
	end
	return Enum.ContextActionResult.Pass
end

-- Change la cible affichée. Une cible qui disparaît/change coupe proprement une
-- réanimation en cours (le serveur l'aurait annulée de toute façon hors portée).
local function setTarget(userId: number?)
	if userId == currentTarget then
		return
	end
	if reviving then
		stopReviving()
	end
	currentTarget = userId
	HudController.setReviveVisible(userId ~= nil)
	if userId ~= nil then
		ContextActionService:BindAction(REVIVE_ACTION, onReviveKey, false, Enum.KeyCode.E)
	else
		ContextActionService:UnbindAction(REVIVE_ACTION)
	end
end

local function onHeartbeat(dt: number)
	scanAccum += dt
	if scanAccum < SCAN_INTERVAL then
		return
	end
	scanAccum = 0
	setTarget(findTarget())
end

function ReviveController.activate()
	if active then
		return
	end
	active = true
	scanAccum = 0

	local reviveBtn = HudController.getButton("Revive")
	if reviveBtn then
		table.insert(connections, (reviveBtn.MouseButton1Down:Connect(startReviving)))
		table.insert(connections, (reviveBtn.MouseButton1Up:Connect(stopReviving)))
	end
	table.insert(connections, (RunService.Heartbeat:Connect(onHeartbeat)))
end

function ReviveController.deactivate()
	if not active then
		return
	end
	active = false

	stopReviving()
	setTarget(nil) -- cache le bouton + délie la touche

	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
end

return ReviveController
