--!strict
-- AmbientController — ambiance « laboratoire abandonné » côté client : lumières de
-- salle qui clignotent + nappe sonore en boucle. Purement local (visuel/audio).

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

-- ─── Nappe sonore d'ambiance (boucle) ───────────────────────────────────
-- ⚠️ Remplaçable : choisis un SFX d'ambiance dans le Toolbox (Creator Store),
-- clic droit → Copy Asset ID, et colle l'ID ici.
local ambient = Instance.new("Sound")
ambient.Name = "LabAmbience"
ambient.SoundId = "rbxassetid://9112775175"
ambient.Looped = true
ambient.Volume = 0.35
ambient.Parent = SoundService
task.spawn(function()
	pcall(function()
		ambient:Play()
	end)
end)

-- ─── Clignotement des lumières de salle ─────────────────────────────────
type Flick = { light: PointLight, base: number, nextAt: number }
local flicks: { Flick } = {}

local function collectLights()
	flicks = {}
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return
	end
	for _, d in map:GetDescendants() do
		-- Uniquement les lampes de salle (parts nommées "Light"), pas la torche/entité.
		if d:IsA("PointLight") and d.Parent and d.Parent.Name == "Light" then
			table.insert(flicks, { light = d, base = d.Brightness, nextAt = math.random() * 4 })
		end
	end
end
collectLights()

-- La map est reclonée à chaque manche → on rescanne si les références sont mortes.
task.spawn(function()
	while true do
		task.wait(6)
		if #flicks == 0 or not (flicks[1].light and flicks[1].light.Parent) then
			collectLights()
		end
	end
end)

RunService.Heartbeat:Connect(function(dt: number)
	for _, f in flicks do
		local l = f.light
		if l and l.Parent then
			f.nextAt -= dt
			if f.nextAt <= 0 then
				l.Enabled = false
				local ref = l
				task.delay(0.03 + math.random() * 0.12, function()
					if ref and ref.Parent then
						ref.Enabled = true
					end
				end)
				f.nextAt = 1.5 + math.random() * 5
			end
		end
	end
end)
