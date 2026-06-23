--!strict
-- InputController — Inputs SURVIVANT : sprint (MAINTIEN) et torche (toggle).
-- Module piloté par init.client (activate/deactivate selon le rôle).
--
-- Mobile-first : touch via les boutons HudController (MouseButton1Down/Up pour le
-- maintien, Activated pour le toggle) ; clavier (test PC) via ContextActionService
-- SANS bouton tactile auto (createTouchButton=false) pour ne pas doubler le HUD.
-- N'envoie que des INTENTIONS ; le serveur (PlayerService) tranche selon la
-- stamina/batterie. On ne suppose donc jamais le succès localement.

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes.RemotesManifest)
local HudController = require(script.Parent.HudController)

local InputController = {}

local localPlayer = Players.LocalPlayer

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

-- Feedback visuel LOCAL : une PointLight dans le HumanoidRootPart du joueur
-- local. Créée côté client → NON répliquée (instance client sous un parent
-- répliqué reste locale) : pas de Remote, c'est purement de l'affichage.
-- ⚠️ MVP : la lumière suit l'intention client (toggle), pas l'état serveur
-- autoritaire ; si la batterie se vide serveur-side, la lumière reste allumée
-- jusqu'au prochain toggle (désync mineure assumée).
local function setTorchLight(on: boolean)
	local character = localPlayer.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local light = hrp:FindFirstChild("TorchLight")
	if not light then
		if not on then
			return -- rien à éteindre
		end
		local pl = Instance.new("PointLight")
		pl.Name = "TorchLight"
		pl.Brightness = 2.5
		pl.Range = 18
		pl.Color = Color3.fromRGB(255, 244, 214)
		pl.Parent = hrp
		light = pl
	end
	(light :: PointLight).Enabled = on
end

local function toggleTorch()
	torchOn = not torchOn
	Remotes.SetTorch:FireServer(torchOn)
	setTorchLight(torchOn) -- feedback visuel local
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
	stopSprint()
	if torchOn then
		torchOn = false
		Remotes.SetTorch:FireServer(false)
	end
	setTorchLight(false) -- éteint la lumière locale dans tous les cas
end

return InputController
