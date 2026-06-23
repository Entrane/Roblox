--!strict
-- InputController — Inputs SURVIVANT : sprint (MAINTIEN) et torche (toggle).
-- Module piloté par init.client (activate/deactivate selon le rôle).
--
-- Mobile-first : touch via les boutons HudController (MouseButton1Down/Up pour le
-- maintien, Activated pour le toggle) ; clavier (test PC) via ContextActionService
-- SANS bouton tactile auto (createTouchButton=false) pour ne pas doubler le HUD.
-- N'envoie que des INTENTIONS ; le serveur (PlayerService) tranche selon la
-- stamina/batterie. On ne suppose donc jamais le succès localement.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local HudController = require(script.Parent.HudController)

local InputController = {}

local SPRINT_ACTION = "SL_Sprint"
local TORCH_ACTION = "SL_Torch"

local active = false
local torchOn = false
-- { any } et non { RBXScriptConnection } : ce type Roblox est inconnu hors Studio
-- et fait échouer la résolution de table.insert à l'analyse. Ces connexions ne
-- servent qu'à être Disconnect, le typage précis n'apporte rien ici.
local connections: { any } = {}

local function startSprint()
	Remotes.SetSprinting:FireServer(true)
end

local function stopSprint()
	Remotes.SetSprinting:FireServer(false)
end

-- La torche n'est qu'une INTENTION ici : le serveur tranche (batterie), et la
-- PointLight est pilotée par HudController d'après l'état autoritaire torchOn
-- reçu via PlayerHud — pas par cette intention locale.
local function toggleTorch()
	torchOn = not torchOn
	Remotes.SetTorch:FireServer(torchOn)
end

-- Sprint clavier : Begin = maintien, End/Cancel = relâche.
local function onSprintKey(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		startSprint()
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		stopSprint()
	end
	return Enum.ContextActionResult.Pass
end

local function onTorchKey(_action: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		toggleTorch()
	end
	return Enum.ContextActionResult.Pass
end

function InputController.activate()
	if active then
		return
	end
	active = true
	torchOn = false

	-- Touch (boutons HUD).
	local sprintBtn = HudController.getButton("Sprint")
	if sprintBtn then
		table.insert(connections, (sprintBtn.MouseButton1Down:Connect(startSprint)))
		table.insert(connections, (sprintBtn.MouseButton1Up:Connect(stopSprint)))
	end
	local torchBtn = HudController.getButton("Torch")
	if torchBtn then
		table.insert(connections, (torchBtn.Activated:Connect(toggleTorch)))
	end

	-- Clavier (test PC).
	ContextActionService:BindAction(SPRINT_ACTION, onSprintKey, false, Enum.KeyCode.LeftShift)
	ContextActionService:BindAction(TORCH_ACTION, onTorchKey, false, Enum.KeyCode.F)
end

function InputController.deactivate()
	if not active then
		return
	end
	active = false

	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)

	ContextActionService:UnbindAction(SPRINT_ACTION)
	ContextActionService:UnbindAction(TORCH_ACTION)

	-- Nettoyage : on coupe sprint et torche en quittant le rôle (état serveur propre).
	-- La PointLight s'éteindra côté HudController (PlayerHud torchOn=false, ou setRole).
	stopSprint()
	if torchOn then
		torchOn = false
		Remotes.SetTorch:FireServer(false)
	end
end

return InputController
