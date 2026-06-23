--[[
	Signal Lost — Générateur de map « bunker laboratoire » (inspiration Among Us).

	USAGE : ouvre Studio sur la place, colle CE script ENTIER dans la barre de
	commande (View > Command Bar) et exécute. Le script DÉTRUIT l'ancienne
	Workspace.Map puis reconstruit tout (sol, plafond, 9 salles, couloirs, objets
	fonctionnels) avec les NOMS EXACTS attendus par les Services. Idempotent :
	relançable à volonté.

	⚠️ À VALIDER DANS STUDIO. Workspace.Map n'est PAS synchronisé par Rojo : ce
	script est la « source » de la map. Après exécution, sauvegarde Map en .rbxm
	(clic droit sur Workspace.Map > Save to File... > place/Map.rbxm).

	Layout (grille 3×3, centres espacés de 48 studs ; X = colonne, Z = rangée) :

	        NO                 N                 NE
	   Sécurité (rouge)  Laboratoire (cyan)  Stockage (orange)
	     FuseSpot5         FuseSpot1           FuseSpot2

	        O                 C                 E
	 Communications (violet) Hub (gris-bleu)  Médical (vert)
	     FuseSpot4          SpawnPoint          FuseSpot3

	        SO                S                 SE
	  Maintenance (sombre)  Réacteur (jaune)  Sas de sortie (lime)
	    (cachette, 2 couloirs) Generator      ExitBarrier + ExitZone

	Connectivité = adjacence de grille (portes orthogonales de 10 studs) → boucles,
	au moins 2 chemins entre salles, pas d'impasse. EXCEPTION voulue : le Sas (SE)
	n'a qu'UNE entrée (depuis le Réacteur), gardée par l'ExitBarrier.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

-- ───────────────────────── Paramètres géométriques ─────────────────────────
local CELL = 48 -- espacement centre-à-centre des salles
local ROOM = 30 -- côté intérieur d'une salle (carré)
local HALF = ROOM / 2 -- 15 : demi-salle (position des murs depuis le centre)
local WALL_H = 18 -- hauteur des murs (plafond fermé à 18)
local WALL_T = 2 -- épaisseur des murs
local DOOR_W = 10 -- largeur des portes et couloirs
local FLOOR_SIZE = 140 -- sol/plafond carrés (empreinte réelle ~126, marge incluse)

-- ───────────────────────── Palette ─────────────────────────
local COL_WALL = Color3.fromRGB(48, 52, 60) -- murs gris foncé
local COL_FLOOR = Color3.fromRGB(20, 24, 36) -- sol bleu nuit
local COL_CEIL = Color3.fromRGB(28, 30, 38) -- plafond gris très foncé

-- ───────────────────────── Reconstruction propre ─────────────────────────
local old = Workspace:FindFirstChild("Map")
if old then
	old:Destroy()
end
local map = Instance.new("Model")
map.Name = "Map"

local partCount = 0

-- Fabrique une Part ancrée standard et l'ajoute au compteur.
local function newPart(name: string, size: Vector3, pos: Vector3, color: Color3, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = pos
	p.Color = color
	p.Material = Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent or map
	partCount += 1
	return p
end

-- ───────────────────────── Sol & plafond ─────────────────────────
-- Sol : top à Y=0 (les murs reposent dessus, centrés à WALL_H/2).
newPart("Floor", Vector3.new(FLOOR_SIZE, 1, FLOOR_SIZE), Vector3.new(0, -0.5, 0), COL_FLOOR)
-- Plafond fermé (précision #1) : bas à Y=WALL_H.
newPart("Ceiling", Vector3.new(FLOOR_SIZE, 1, FLOOR_SIZE), Vector3.new(0, WALL_H + 0.5, 0), COL_CEIL)

-- ───────────────────────── Définition des salles ─────────────────────────
-- col/row ∈ {-1,0,1} → centre monde (col*CELL, row*CELL). accent = teinte néon.
local rooms = {
	{ key = "NW", col = -1, row = -1, name = "Securite", accent = Color3.fromRGB(220, 60, 60) },
	{ key = "N", col = 0, row = -1, name = "Laboratoire", accent = Color3.fromRGB(60, 200, 220) },
	{ key = "NE", col = 1, row = -1, name = "Stockage", accent = Color3.fromRGB(230, 150, 50) },
	{ key = "W", col = -1, row = 0, name = "Communications", accent = Color3.fromRGB(170, 90, 220) },
	{ key = "C", col = 0, row = 0, name = "Hub", accent = Color3.fromRGB(120, 150, 190) },
	{ key = "E", col = 1, row = 0, name = "Medical", accent = Color3.fromRGB(70, 210, 110) },
	{ key = "SW", col = -1, row = 1, name = "Maintenance", accent = Color3.fromRGB(90, 95, 105) },
	{ key = "S", col = 0, row = 1, name = "Reacteur", accent = Color3.fromRGB(230, 210, 60) },
	{ key = "SE", col = 1, row = 1, name = "Sas", accent = Color3.fromRGB(150, 240, 120) },
}

-- Index (col,row) → salle, pour résoudre les voisins.
local byCell: { [string]: any } = {}
for _, r in rooms do
	byCell[r.col .. "," .. r.row] = r
end

-- ───────────────────────── Graphe d'adjacence (portes) ─────────────────────────
-- Grille complète SAUF l'arête E–SE : le Sas garde une entrée unique (gardée par
-- l'ExitBarrier). Maintenance (SW) conserve 2 couloirs (W et S) — précision #3.
local edges = {
	-- horizontales
	{ "-1,-1", "0,-1" }, { "0,-1", "1,-1" },
	{ "-1,0", "0,0" }, { "0,0", "1,0" },
	{ "-1,1", "0,1" }, { "0,1", "1,1" },
	-- verticales
	{ "-1,-1", "-1,0" }, { "-1,0", "-1,1" },
	{ "0,-1", "0,0" }, { "0,0", "0,1" },
	{ "1,-1", "1,0" }, -- (1,0)-(1,1) volontairement absente → Sas mono-entrée
}

local edgeSet: { [string]: boolean } = {}
local function edgeKey(a: string, b: string): string
	return (a < b) and (a .. "|" .. b) or (b .. "|" .. a)
end
for _, e in edges do
	edgeSet[edgeKey(e[1], e[2])] = true
end

-- Une salle a-t-elle une porte dans la direction donnée ?
local DIRS = {
	N = { dc = 0, dr = -1 },
	S = { dc = 0, dr = 1 },
	E = { dc = 1, dr = 0 },
	W = { dc = -1, dr = 0 },
}
local function hasDoor(room: any, dir: string): boolean
	local d = DIRS[dir]
	local nKey = (room.col + d.dc) .. "," .. (room.row + d.dr)
	if not byCell[nKey] then
		return false
	end
	return edgeSet[edgeKey(room.col .. "," .. room.row, nKey)] == true
end

-- ───────────────────────── Construction d'un mur (avec porte optionnelle) ─────────────────────────
-- Mur N/S : court le long de X à z = cz ∓ HALF. Mur E/W : le long de Z à x = cx ∓ HALF.
-- Longueur ROOM+WALL_T pour fermer proprement les coins (chevauchement assumé).
local SEG_FULL = ROOM + WALL_T -- 32
local SEG_SIDE = (SEG_FULL - DOOR_W) / 2 -- 11 : longueur d'un demi-segment de porte
local SEG_OFFSET = DOOR_W / 2 + SEG_SIDE / 2 -- 10.5 : décalage du centre d'un demi-segment

local function buildWall(room: any, dir: string)
	local cx = room.col * CELL
	local cz = room.row * CELL
	local door = hasDoor(room, dir)
	local y = WALL_H / 2

	if dir == "N" or dir == "S" then
		local z = (dir == "N") and (cz - HALF) or (cz + HALF)
		if door then
			newPart("Wall", Vector3.new(SEG_SIDE, WALL_H, WALL_T), Vector3.new(cx - SEG_OFFSET, y, z), COL_WALL)
			newPart("Wall", Vector3.new(SEG_SIDE, WALL_H, WALL_T), Vector3.new(cx + SEG_OFFSET, y, z), COL_WALL)
		else
			newPart("Wall", Vector3.new(SEG_FULL, WALL_H, WALL_T), Vector3.new(cx, y, z), COL_WALL)
		end
	else -- E / W
		local x = (dir == "E") and (cx + HALF) or (cx - HALF)
		if door then
			newPart("Wall", Vector3.new(WALL_T, WALL_H, SEG_SIDE), Vector3.new(x, y, cz - SEG_OFFSET), COL_WALL)
			newPart("Wall", Vector3.new(WALL_T, WALL_H, SEG_SIDE), Vector3.new(x, y, cz + SEG_OFFSET), COL_WALL)
		else
			newPart("Wall", Vector3.new(WALL_T, WALL_H, SEG_FULL), Vector3.new(x, y, cz), COL_WALL)
		end
	end
end

-- ───────────────────────── Murs + accent + lumière par salle ─────────────────────────
for _, room in rooms do
	local cx = room.col * CELL
	local cz = room.row * CELL
	for dir in DIRS do
		buildWall(room, dir)
	end

	-- Bandeau d'accent néon le long du mur nord intérieur (repère visuel par salle).
	local accent = newPart(
		"Accent",
		Vector3.new(ROOM - 2, 0.3, 1.5),
		Vector3.new(cx, 0.15, cz - HALF + 1.5),
		room.accent
	)
	accent.Material = Enum.Material.Neon
	accent.CanCollide = false -- simple liseré au sol, ne doit pas gêner les portes

	-- Lumière d'ambiance (bunker sombre → chaque salle a sa source colorée).
	local light = Instance.new("PointLight")
	light.Color = room.accent
	light.Brightness = 1.6
	light.Range = 26
	light.Parent = accent
end

-- ───────────────────────── Couloirs (murs latéraux des portes) ─────────────────────────
-- Pour chaque arête, 2 murs latéraux bordent le couloir de 10 studs reliant les
-- deux portes. Longueur (CELL-ROOM)+WALL_T pour rejoindre les murs des salles.
local CORR_LEN = (CELL - ROOM) + WALL_T -- 20
for _, e in edges do
	local a = byCell[e[1]]
	local b = byCell[e[2]]
	local ax, az = a.col * CELL, a.row * CELL
	local bx, bz = b.col * CELL, b.row * CELL
	local mx, mz = (ax + bx) / 2, (az + bz) / 2
	local y = WALL_H / 2
	local offset = DOOR_W / 2 + WALL_T / 2 -- 6

	if az == bz then
		-- couloir horizontal (le long de X) → murs latéraux décalés en Z
		newPart("Corridor", Vector3.new(CORR_LEN, WALL_H, WALL_T), Vector3.new(mx, y, mz - offset), COL_WALL)
		newPart("Corridor", Vector3.new(CORR_LEN, WALL_H, WALL_T), Vector3.new(mx, y, mz + offset), COL_WALL)
	else
		-- couloir vertical (le long de Z) → murs latéraux décalés en X
		newPart("Corridor", Vector3.new(WALL_T, WALL_H, CORR_LEN), Vector3.new(mx - offset, y, mz), COL_WALL)
		newPart("Corridor", Vector3.new(WALL_T, WALL_H, CORR_LEN), Vector3.new(mx + offset, y, mz), COL_WALL)
	end
end

-- ───────────────────────── Objets fonctionnels (NOMS EXACTS) ─────────────────────────
local function centerOf(key: string): (number, number)
	local r = byCell[key]
	return r.col * CELL, r.row * CELL
end

-- SpawnPoint au Hub (C). RoundService téléporte à spawnPoint.CFrame + offset +Y.
local sx, sz = centerOf("0,0")
local spawn = newPart("SpawnPoint", Vector3.new(6, 1, 6), Vector3.new(sx, 0.5, sz), Color3.fromRGB(120, 150, 190))
spawn.Material = Enum.Material.Metal

-- FuseSpots : dossier intermédiaire + 5 spots dans N, NE, E, W, NO.
local fuseFolder = Instance.new("Folder")
fuseFolder.Name = "FuseSpots"
fuseFolder.Parent = map

local fuseLayout = {
	{ n = "FuseSpot1", cell = "0,-1" }, -- Laboratoire (N)
	{ n = "FuseSpot2", cell = "1,-1" }, -- Stockage (NE)
	{ n = "FuseSpot3", cell = "1,0" }, -- Médical (E)
	{ n = "FuseSpot4", cell = "-1,0" }, -- Communications (W)
	{ n = "FuseSpot5", cell = "-1,-1" }, -- Sécurité (NO)
}
for _, f in fuseLayout do
	local fx, fz = centerOf(f.cell)
	local spot = newPart(f.n, Vector3.new(2, 1, 2), Vector3.new(fx, 0.5, fz), Color3.fromRGB(230, 200, 60), fuseFolder)
	spot.Material = Enum.Material.Metal
end

-- Generator au Réacteur (S). BasePart (PAS un Model) ; le prompt de dépôt est créé en code.
local gx, gz = centerOf("0,1")
local gen = newPart("Generator", Vector3.new(6, 6, 4), Vector3.new(gx, 3, gz), Color3.fromRGB(90, 90, 100))
gen.Material = Enum.Material.DiamondPlate

-- Sas de sortie (SE). Entrée unique = porte OUEST (depuis le Réacteur).
local ex, ez = centerOf("1,1")
-- ExitBarrier : bloque la porte ouest du Sas (CanCollide=true au départ ;
-- FuseService la passe à CanCollide=false + Transparency=0.7 au 5/5).
local barrier = newPart(
	"ExitBarrier",
	Vector3.new(3, WALL_H, DOOR_W),
	Vector3.new(ex - HALF, WALL_H / 2, ez),
	Color3.fromRGB(150, 240, 120)
)
barrier.Material = Enum.Material.ForceField
barrier.Transparency = 0
barrier.CanCollide = true

-- ExitZone : AU FOND du Sas (mur est), pas juste derrière la barrière (précision #2).
-- Le joueur traverse toute la salle après avoir franchi la barrière.
local zone = newPart(
	"ExitZone",
	Vector3.new(8, 1, 8),
	Vector3.new(ex + HALF - 5, 0.5, ez),
	Color3.fromRGB(150, 240, 120)
)
zone.Material = Enum.Material.Neon
zone.CanCollide = false
zone.CanTouch = true
zone.Transparency = 0.35

-- ───────────────────────── Atmosphère bunker (Lighting) ─────────────────────────
Lighting.ClockTime = 0 -- nuit
Lighting.Brightness = 1 -- faible (le bunker est fermé)
Lighting.Ambient = Color3.fromRGB(28, 30, 38)
Lighting.OutdoorAmbient = Color3.fromRGB(18, 20, 28)
Lighting.GlobalShadows = true
Lighting.EnvironmentDiffuseScale = 0.2
Lighting.EnvironmentSpecularScale = 0.2
Lighting.FogColor = Color3.fromRGB(18, 22, 32)
Lighting.FogStart = 10
Lighting.FogEnd = 75

-- ───────────────────────── Finalisation ─────────────────────────
map.Parent = Workspace
print(string.format("[Signal Lost] Map reconstruite : %d Parts (budget ≤500). Pense à sauver Workspace.Map en place/Map.rbxm.", partCount))
