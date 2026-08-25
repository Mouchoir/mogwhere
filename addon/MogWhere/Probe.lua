local _, ns = ...

--------------------------------------------------------------------------------
-- Wardrobe discovery
--
-- The display layer has to hang off the Appearances tab, and no documentation
-- states reliably what that tab is called on this build. Rather than guess at
-- frame names and ship something that silently does nothing, this records what
-- actually exists and what a wardrobe button actually carries.
--
-- It also runs the client layer against real appearances, so the report answers
-- the only question that matters before any interface work starts: does
-- GetAppearanceSourceDrops really return boss and instance names here.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

local PROBE_VERSION = 2

-- Every plausible home for the wardrobe, from the modern layout down.
local CANDIDATES = {
	"WardrobeCollectionFrame",
	"WardrobeCollectionFrame.ItemsCollectionFrame",
	"WardrobeCollectionFrame.ItemsCollectionFrame.Models",
	"WardrobeCollectionFrame.SetsCollectionFrame",
	"WardrobeCollectionFrame.SetsTransmogFrame",
	"WardrobeCollectionFrame.FilterButton",
	"WardrobeCollectionFrame.searchBox",
	"WardrobeFrame",
	"WardrobeTransmogFrame",
	"CollectionsJournal",
	"CollectionsJournalTab1",
}

local function Resolve(path)
	local node = _G
	for part in path:gmatch("[^.]+") do
		if type(node) ~= "table" then return nil end
		node = node[part]
		if node == nil then return nil end
	end
	return node
end

-- Sorted key names, so two reports can be diffed by eye.
local function KeyNames(value, limit)
	if type(value) ~= "table" then return nil end

	local keys = {}
	for key in pairs(value) do
		if type(key) == "string" then keys[#keys + 1] = key end
	end
	table.sort(keys)

	if limit and #keys > limit then
		local trimmed = {}
		for index = 1, limit do trimmed[index] = keys[index] end
		trimmed[limit + 1] = "... " .. (#keys - limit) .. " more"
		keys = trimmed
	end

	return table.concat(keys, " ")
end

local function FunctionNames(namespace)
	if type(namespace) ~= "table" then return nil end

	local names = {}
	for key, value in pairs(namespace) do
		if type(key) == "string" and type(value) == "function" then
			names[#names + 1] = key
		end
	end
	table.sort(names)

	return #names > 0 and table.concat(names, " ") or nil
end

--------------------------------------------------------------------------------
-- Sampling real appearances
--
-- A handful is enough. The point is to see the shape of what comes back, not to
-- walk fifteen thousand visuals during a probe.
--------------------------------------------------------------------------------

-- One sample per source type rather than the first few of one category. The
-- first run of this probe returned four appearances that happened to be a
-- vendor, two world drops and a profession, and therefore proved nothing about
-- the claim this whole design rests on: that GetAppearanceSourceDrops really
-- returns instance and boss names on this client. Only a source of type 1 can
-- answer that, so the sampler now hunts for one of each.
local SAMPLE_CATEGORIES = { 1, 3, 4, 8, 11 }
local SAMPLE_BUDGET = 900
local SAMPLE_TYPES = 6

local function SampleSources()
	local collection = C_TransmogCollection
	local categories = Fn(collection and collection.GetCategoryAppearances)
	if not categories then return nil end

	local out, found, scanned = {}, 0, 0

	for _, category in ipairs(SAMPLE_CATEGORIES) do
		if found >= SAMPLE_TYPES or scanned >= SAMPLE_BUDGET then break end

		local appearances = Try(categories, category)
		if type(appearances) == "table" then
			for _, appearance in ipairs(appearances) do
				if found >= SAMPLE_TYPES or scanned >= SAMPLE_BUDGET then break end
				scanned = scanned + 1

				local visualID = type(appearance) == "table" and appearance.visualID or appearance
				local sources = visualID and ns.SourcesForVisual(visualID)
				local sourceID = sources and sources[1]
				local resolved = sourceID and ns.ClientSource(sourceID) or nil
				local sourceType = resolved and resolved.sourceType

				-- Keyed by source type, so each kind is recorded exactly once.
				if sourceType and not out[sourceType] then
					found = found + 1
					out[sourceType] = {
						category = category,
						visualID = visualID,
						sourceID = sourceID,
						itemID = resolved.itemID,
						itemLink = resolved.itemLink,
						sourceLabel = resolved.sourceLabel,
						-- Obtainable on this version at all?
						playerCanCollect = resolved.playerCanCollect,
						accountCanCollect = resolved.accountCanCollect,
						useError = resolved.useError,
						-- The whole reason this probe exists.
						drops = resolved.drops,
						holiday = resolved.holiday,
						requirements = resolved.requirements,
						-- And whether the vendor layers have anything to say.
						offers = ns.Offers(resolved.itemID, sourceID),
					}
				end
			end
		end
	end

	return next(out) and { bySourceType = out, scanned = scanned } or nil
end

--------------------------------------------------------------------------------

function ns.Probe()
	local db = ns.db
	if not db then return false end

	ns.Load("Blizzard_Collections")

	local frames = {}
	for _, path in ipairs(CANDIDATES) do
		local value = Resolve(path)
		if value == nil then
			frames[path] = "absent"
		else
			local kind = type(value)
			local note = kind
			if kind == "table" then
				local count = #value
				if count > 0 then note = note .. ", " .. count .. " entries" end
				local names = KeyNames(value, 24)
				if names then note = note .. " | " .. names end
			end
			frames[path] = note
		end
	end

	-- What one wardrobe button carries, which is where a visualID has to come
	-- from when the player hovers it.
	local models = Resolve("WardrobeCollectionFrame.ItemsCollectionFrame.Models")
	local button = type(models) == "table" and models[1] or nil

	local report = {
		version = PROBE_VERSION,
		at = GetServerTime and GetServerTime() or nil,
		build = select(2, GetBuildInfo()),
		interface = select(4, GetBuildInfo()),
		locale = GetLocale and GetLocale() or nil,
		collectionsLoaded = ns.IsLoaded("Blizzard_Collections"),
		frames = frames,
		buttonKeys = KeyNames(button, 40),
		buttonVisualInfoKeys = button and KeyNames(button.visualInfo, 40) or nil,
		transmogCollectionAPI = FunctionNames(C_TransmogCollection),
		transmogAPI = FunctionNames(C_Transmog),
		attLoaded = ns.HasATT(),
		samples = SampleSources(),
	}

	db.probe = report
	return true
end
