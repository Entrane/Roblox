--!strict
-- HudController — Couche UI pure : construit le ScreenGui et les boutons d'action,
-- montre/cache les groupes selon le rôle, affiche l'état (cooldown/effet) des
-- capacités Écho. AUCUNE logique de jeu ni Remote ici : les controllers branchent
-- leurs inputs sur les boutons exposés (getButton) et poussent l'état via
-- setAbilityState. Partagé par les controllers survivant ET Écho (instance de
-- module unique, mise en cache par require).
--
-- HUD MINIMAL ASSUMÉ : boutons d'action seulement (+ cooldowns Écho via EchoState).
-- Pas de barres stamina/batterie ni compteur fusibles/timer : ces valeurs ne sont
-- pas répliquées au client aujourd'hui (HudState viendra en fast-follow).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)

local HudController = {}

local localPlayer = Players.LocalPlayer

local screenGui: ScreenGui? = nil
local buttons: { [string]: TextButton } = {}

-- Groupes par rôle (pour show/hide). Revive est survivant mais CONTEXTUEL :
-- ReviveController gère sa visibilité, il n'est pas montré par setRole.
local SURVIVOR_GROUP = { "Sprint", "Torch" }
local ECHO_GROUP = { "Howl", "Frenzy" }

-- Libellés de base (réutilisés par setAbilityState pour reconstruire le texte).
local LABELS: { [string]: string } = {
	Sprint = "Sprint",
	Torch = "Torche",
	Revive = "Réanimer",
	Howl = "Hurlement",
	Frenzy = "Frénésie",
}

-- Fabrique un TextButton minimal, empilé en bas à droite (zone du pouce).
local function makeButton(name: string, order: number): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Text = LABELS[name] or name
	btn.Size = UDim2.fromOffset(120, 60)
	btn.Position = UDim2.new(1, -132, 1, -(order * 68) - 12)
	btn.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
	btn.TextColor3 = Color3.fromRGB(235, 235, 235)
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Active = true
	btn.Visible = false
	return btn
end

function HudController.init()
	if screenGui then
		return -- idempotent (init.client l'appelle ; les controllers en dépendent)
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SignalLostHUD"
	gui.ResetOnSpawn = false -- survit aux respawns (le rôle est stable sur la manche)
	gui.IgnoreGuiInset = true
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	local container = Instance.new("Frame")
	container.Name = "Actions"
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Parent = gui

	-- Survivant
	buttons.Sprint = makeButton("Sprint", 3)
	buttons.Torch = makeButton("Torch", 2)
	buttons.Revive = makeButton("Revive", 1)
	-- Écho
	buttons.Howl = makeButton("Howl", 2)
	buttons.Frenzy = makeButton("Frenzy", 1)

	for _, btn in buttons do
		btn.Parent = container
	end

	screenGui = gui
end

-- Affiche le groupe du rôle, cache l'autre. Revive reste caché (contextuel).
function HudController.setRole(role: Types.Role?)
	local function setGroup(names: { string }, visible: boolean)
		for _, n in names do
			local b = buttons[n]
			if b then
				b.Visible = visible
			end
		end
	end
	setGroup(SURVIVOR_GROUP, role == Types.Role.Survivor)
	setGroup(ECHO_GROUP, role == Types.Role.Echo)
	if buttons.Revive then
		buttons.Revive.Visible = false
	end
end

-- Référence d'un bouton pour qu'un controller y branche ses inputs. nil si HUD
-- pas encore construit ou nom inconnu.
function HudController.getButton(name: string): TextButton?
	return buttons[name]
end

function HudController.setReviveVisible(visible: boolean)
	if buttons.Revive then
		buttons.Revive.Visible = visible
	end
end

-- Reflète l'état d'une capacité Écho sur son bouton (couleur + décompte).
-- Alimenté par EchoState (cadence du pulse). cooldownRemaining > 0 → en recharge ;
-- activeRemaining > 0 → effet en cours ; sinon prêt.
function HudController.setAbilityState(abilityId: Types.AbilityId, cooldownRemaining: number, activeRemaining: number)
	local name: string? = nil
	if abilityId == Types.AbilityId.Howl then
		name = "Howl"
	elseif abilityId == Types.AbilityId.Frenzy then
		name = "Frenzy"
	end
	if not name then
		return
	end
	local btn = buttons[name]
	if not btn then
		return
	end
	local label = LABELS[name] or name
	if cooldownRemaining > 0 then
		btn.Text = string.format("%s\n%ds", label, math.ceil(cooldownRemaining))
		btn.BackgroundColor3 = Color3.fromRGB(70, 30, 30) -- en recharge
	elseif activeRemaining > 0 then
		btn.Text = label .. "\n(actif)"
		btn.BackgroundColor3 = Color3.fromRGB(30, 70, 40) -- effet en cours
	else
		btn.Text = label
		btn.BackgroundColor3 = Color3.fromRGB(40, 40, 45) -- prêt
	end
end

return HudController
