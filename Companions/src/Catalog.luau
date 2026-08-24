--!strict

-- Discovers pet models. The schema is fixed: a folder under ReplicatedStorage holding any
-- number of Models, one per pet, where the Model's Name is the pet id. Subfolders are
-- walked as well and the immediate subfolder name is kept as the pet's category, so
-- content can be grouped without the rest of the system knowing about groups.
--
-- REPLICATEDSTORAGE, NOT SERVERSTORAGE. The models used to be server-only, which was tidy right
-- up until a client wanted to SHOW one: the loadout fell back to 2D portraits and the chest
-- reveal could not stage the companion it was handing over, both because a viewport cannot
-- render a model the client is not allowed to see. The rigs already replicate into the world as
-- live pets, so this costs no bandwidth that was not already being spent.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(script.Parent.Config)

export type Entry = {
	id: string,
	category: string?, -- name of the subfolder the model was found in, nil at the top level
	model: Model,
}

local Catalog = {}

Catalog.entries = {} :: { Entry }
Catalog.byId = {} :: { [string]: Entry }

-- A pet needs a part to hang constraints off. Models that are only meshes-in-folders or
-- empty placeholders are skipped rather than spawned as an invisible, unmovable clone.
local function hasPart(model: Model): boolean
	if model.PrimaryPart then
		return true
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

local function collect(container: Instance, category: string?, entries: { Entry })
	for _, child in container:GetChildren() do
		if child:IsA("Model") then
			if not hasPart(child) then
				warn(`[Companions] Pet model "{child.Name}" has no BasePart; skipping it.`)
				continue
			end
			table.insert(entries, { id = child.Name, category = category, model = child })
		elseif child:IsA("Folder") then
			-- Only the first level of nesting names a category; deeper folders inherit it.
			collect(child, category or child.Name, entries)
		end
	end
end

-- Mirrors the id list into its own folder: the models are reachable now, but a NAME LIST is a
-- cheaper thing to read than a folder walk, and the Cmdr petId type autocompletes off it.
-- Republished on every load so a reload cannot leave stale names behind.
local function publish(entries: { Entry })
	local folderName = Config.catalogFolderName
	if not folderName then
		return
	end

	local existing = ReplicatedStorage:FindFirstChild(folderName)
	local folder: Instance
	if existing then
		folder = existing
		folder:ClearAllChildren()
	else
		local created = Instance.new("Folder")
		created.Name = folderName
		created.Parent = ReplicatedStorage
		folder = created
	end

	for _, entry in entries do
		local value = Instance.new("StringValue")
		value.Name = entry.id
		value.Value = entry.category or ""
		value.Parent = folder
	end
end

-- Rebuilds the catalog from the asset folder. Safe to call again at runtime after adding
-- models to the folder; it replaces the previous contents rather than appending.
function Catalog.load(folderName: string): number
	local folder = ReplicatedStorage:FindFirstChild(folderName)
	if not folder then
		warn(`[Companions] No folder named "{folderName}" under ReplicatedStorage; no pets are available.`)
		Catalog.entries = {}
		Catalog.byId = {}
		publish(Catalog.entries)
		return 0
	end

	local entries: { Entry } = {}
	collect(folder, nil, entries)

	local byId: { [string]: Entry } = {}
	for index = #entries, 1, -1 do
		local entry = entries[index]
		if byId[entry.id] then
			-- Two models with the same name would make equip(id) ambiguous, so the
			-- duplicate is dropped instead of silently shadowing the first one.
			warn(`[Companions] Duplicate pet id "{entry.id}"; only one model may use that name.`)
			table.remove(entries, index)
			continue
		end
		byId[entry.id] = entry
	end

	if #entries == 0 then
		warn(`[Companions] "{folderName}" under ReplicatedStorage holds no usable pet models.`)
	end

	Catalog.entries = entries
	Catalog.byId = byId
	publish(entries)
	return #entries
end

function Catalog.get(petId: string): Entry?
	return Catalog.byId[petId]
end

-- Takes the Random from the caller so a host game can keep its runs reproducible.
function Catalog.pick(rng: Random): Entry?
	if #Catalog.entries == 0 then
		return nil
	end
	return Catalog.entries[rng:NextInteger(1, #Catalog.entries)]
end

function Catalog.ids(): { string }
	local ids = table.create(#Catalog.entries)
	for _, entry in Catalog.entries do
		table.insert(ids, entry.id)
	end
	return ids
end

return Catalog
