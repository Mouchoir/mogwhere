local _, ns = ...

--------------------------------------------------------------------------------
-- Layer 1: everything the client already knows
--
-- This layer ships no data and can never go stale. It is also more generous than
-- the Appearances tab lets on: for anything that drops, the client hands over the
-- instance, the boss and the difficulties, already localized. The tab reduces all
-- of that to the single word "Drop".
--
-- What the client genuinely does not know, and no amount of API archaeology will
-- produce, is which vendor sells an item, what it costs and where that vendor
-- stands. Those three are the entire job of layers 2 and 3.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

-- Written only under /mw debug, same gate as everywhere else.
local function Note(key, value)
	if not (MogWhereDB and MogWhereDB.config and MogWhereDB.config.debug) then return end
	MogWhereDB.diag = MogWhereDB.diag or {}
	MogWhereDB.diag["src_" .. key] = value
end

--------------------------------------------------------------------------------
-- Pattern building
--
-- Requirement lines are matched through the client's own format strings rather
-- than hardcoded English. ITEM_REQ_REPUTATION is "Requires %s - %s" on an enUS
-- client and the frFR equivalent on this one, so turning the global itself into a
-- capture pattern makes the match work in every language without a translation
-- table of our own.
--------------------------------------------------------------------------------

local patternCache = {}

local function PatternFrom(globalName)
	if patternCache[globalName] ~= nil then return patternCache[globalName] or nil end

	local format = _G[globalName]
	if type(format) ~= "string" then
		patternCache[globalName] = false
		return nil
	end

	-- Escape the Lua pattern metacharacters the format string may contain, then
	-- turn each placeholder into a capture.
	local pattern = format:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
	pattern = pattern:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")

	patternCache[globalName] = pattern
	return pattern
end

--------------------------------------------------------------------------------
-- Source resolution
--------------------------------------------------------------------------------

-- GetAppearanceSourceInfo changed shape across engine versions: it answers a
-- struct on recent builds and a plain tuple on older ones. Both are accepted
-- here rather than betting on either.
function ns.AppearanceSourceInfo(sourceID)
	local get = Fn(C_TransmogCollection and C_TransmogCollection.GetAppearanceSourceInfo)
	if not get then return nil end

	local first, appearanceID, canHaveIllusion, icon, isCollected, itemLink,
		transmogLink, sourceType = Try(get, sourceID)

	if type(first) == "table" then
		return {
			categoryID = first.category,
			visualID = first.itemAppearanceID,
			icon = first.icon,
			isCollected = first.isCollected,
			itemLink = first.itemLink,
			sourceType = first.sourceType,
		}
	end

	if first == nil then return nil end

	return {
		categoryID = first,
		visualID = appearanceID,
		canHaveIllusion = canHaveIllusion,
		icon = icon,
		isCollected = isCollected,
		itemLink = itemLink,
		transmogLink = transmogLink,
		sourceType = sourceType,
	}
end

-- The boss and dungeon detail, which is the part the interface throws away.
local function Drops(sourceID)
	local get = Fn(C_TransmogCollection and C_TransmogCollection.GetAppearanceSourceDrops)
	if not get then return nil end

	local list = Try(get, sourceID)
	if type(list) ~= "table" or #list == 0 then return nil end

	local out = {}
	for _, drop in ipairs(list) do
		if type(drop) == "table" and (drop.instance or drop.encounter) then
			out[#out + 1] = {
				instance = drop.instance,
				encounter = drop.encounter,
				-- Both arrive as arrays of localized strings.
				difficulties = drop.difficulties,
				tiers = drop.tiers,
			}
		end
	end

	return #out > 0 and out or nil
end

-- Reputation and level gates, read from the item tooltip because they exist
-- nowhere else that an addon can reach.
function ns.Requirements(itemLink)
	local lines = ns.TooltipLines(itemLink)
	if not lines then return nil end

	local repPattern = PatternFrom("ITEM_REQ_REPUTATION")
	local levelPattern = PatternFrom("ITEM_MIN_LEVEL")

	local out
	for _, line in ipairs(lines) do
		if repPattern then
			local faction, standing = line:match(repPattern)
			if faction and standing then
				out = out or {}
				out.factionName, out.factionStanding = faction, standing
			end
		end
		if levelPattern then
			local level = line:match(levelPattern)
			if level then
				out = out or {}
				out.requiredLevel = tonumber(level)
			end
		end
	end

	return out
end

--------------------------------------------------------------------------------
-- Obtainability
--
-- The single most useful thing this addon can say, and the interface never says
-- it. This client ships the full modern appearance table, so the wardrobe lists
-- thousands of visuals that exist only in retail and can never be earned here.
-- The probe caught one on the very first tile of the head category: item 170206,
-- which the client labels "Vendor" and which AllTheThings files under a patch
-- 8.3.0 holiday quest. There is no vendor to walk to. There never was, on this
-- version.
--
-- Telling a collector "do not bother with this one" is worth more than telling
-- them where forty others are, and it costs one call.
--------------------------------------------------------------------------------

function ns.CanCollect(sourceID)
	local collection = C_TransmogCollection
	local player = Try(Fn(collection and collection.PlayerCanCollectSource), sourceID)
	local account = Try(Fn(collection and collection.AccountCanCollectSource), sourceID)
	return player, account
end

--------------------------------------------------------------------------------
-- Achievements
--
-- Entirely client side, and richer than anything a shipped database could offer:
-- the name, the description, whether it is already earned, and the live criteria
-- count for this character. No dependency contributes anything here.
--------------------------------------------------------------------------------

function ns.AchievementDetail(achievementID)
	if type(achievementID) ~= "number" then return nil end

	local get = Fn(GetAchievementInfo)
	if not get then return nil end

	local _, name, _, completed, _, _, _, description = Try(get, achievementID)
	if not name then return nil end

	local out = {
		name = name,
		description = description,
		completed = completed and true or nil,
	}

	-- Progress, counted as satisfied criteria rather than as a raw quantity,
	-- because a criteria count is what the achievement UI itself shows.
	--
	-- The missing ones are collected by name, and the satisfied ones are not. A
	-- list of what is already done is a trophy; a list of what is left is a to do
	-- list, and only one of the two tells the player where to go next.
	local numCriteria = Fn(GetAchievementNumCriteria)
	local criteriaInfo = Fn(GetAchievementCriteriaInfo)
	if numCriteria and criteriaInfo then
		local total = Try(numCriteria, achievementID) or 0
		if total > 0 then
			local done, missing = 0, {}
			for index = 1, total do
				local text, _, criteriaCompleted = Try(criteriaInfo, achievementID, index)
				if criteriaCompleted then
					done = done + 1
				elseif type(text) == "string" and text ~= "" then
					missing[#missing + 1] = text
				end
			end
			out.criteriaDone, out.criteriaTotal = done, total
			out.missing = #missing > 0 and missing or nil
		end
	end

	return out
end

--------------------------------------------------------------------------------
-- Naming a place from an id
--
-- All three come from the client, already localized, so a dependency supplies the
-- id and the game supplies the word. That division is deliberate: it means these
-- names are correct in every language without anybody translating anything.
--------------------------------------------------------------------------------

-- The Encounter Journal has to be loaded before any EJ function answers anything.
--
-- This is why instance and boss names came back empty while the coordinates were
-- perfectly right: the ids were there, the resolver was there, and the API was
-- silent because its addon had never been pulled in. Loading on demand, once, is
-- the whole fix. The same trick the wardrobe needed for Blizzard_Collections.
local journalLoaded

local function Journal()
	if journalLoaded == nil then
		journalLoaded = ns.Load("Blizzard_EncounterJournal")
	end
	return journalLoaded
end

function ns.InstanceName(instanceID, instanceMapID)
	-- The journal first, because when it answers it gives the name players read in
	-- the Adventure Guide. But it only knows instances this client shipped with, so
	-- the map is the fallback and it is the one that works for old content.
	if type(instanceID) == "number" and Journal() then
		local name = Try(Fn(EJ_GetInstanceInfo), instanceID)
		if type(name) == "string" and name ~= "" then
			Note("instanceRoute", "journal")
			return name
		end
	end

	if type(instanceMapID) == "number" then
		local info = Try(Fn(C_Map and C_Map.GetMapInfo), instanceMapID)
		local name = type(info) == "table" and info.name or nil
		if type(name) == "string" and name ~= "" then
			Note("instanceRoute", "map")
			return name
		end
	end

	Note("instanceRoute", "none")
	return nil
end

function ns.EncounterName(encounterID)
	if type(encounterID) ~= "number" then return nil end
	if not Journal() then return nil end

	local name = Try(Fn(EJ_GetEncounterInfo), encounterID)
	return type(name) == "string" and name ~= "" and name or nil
end

function ns.DifficultyName(difficultyID)
	if type(difficultyID) ~= "number" then return nil end
	local name = Try(Fn(GetDifficultyInfo), difficultyID)
	return type(name) == "string" and name ~= "" and name or nil
end

--------------------------------------------------------------------------------
-- Reputation gates
--
-- Their data records the requirement, the client records where you actually
-- stand, and the useful sentence needs both. So this answers three things: which
-- faction, what it takes, and whether you are already there.
--
-- The required figure arrives in two shapes. A small number is a standing index,
-- 1 through 8, hated up to exalted. A large one is a raw reputation total, which
-- is why 42000 shows up in their tables: that is exalted expressed as earned
-- points. Both are accepted rather than betting on one.
--------------------------------------------------------------------------------

local MAX_STANDING = 8

-- Absolute reputation thresholds, lowest first, paired with their standing index.
-- A requirement of 42000 is not a number a player can act on; it is the point
-- where Exalted begins, and that is what the tooltip itself says. Printing the
-- raw figure was passing our own homework to the reader.
local THRESHOLDS = {
	{ -42000, 1 }, { -6000, 2 }, { -3000, 3 }, { 0, 4 },
	{ 3000, 5 }, { 9000, 6 }, { 21000, 7 }, { 42000, 8 },
}

local function StandingFromValue(value)
	local best
	for _, row in ipairs(THRESHOLDS) do
		if value >= row[1] then best = row[2] end
	end
	return best
end

local function StandingLabel(standingID)
	if type(standingID) ~= "number" then return nil end
	local label = _G["FACTION_STANDING_LABEL" .. standingID]
	return type(label) == "string" and label or nil
end

function ns.ReputationGate(spec)
	if type(spec) ~= "table" then return nil end

	local factionID, required = spec[1], spec[2]
	if type(factionID) ~= "number" or type(required) ~= "number" then return nil end

	local byID = Fn(GetFactionInfoByID)
	local name, standingID, value

	if byID then
		local n, _, standing, _, _, bar = Try(byID, factionID)
		name, standingID, value = n, standing, bar
	end

	if not name then
		local modern = Fn(C_Reputation and C_Reputation.GetFactionDataByID)
		local data = modern and Try(modern, factionID) or nil
		if type(data) == "table" then
			name = data.name
			standingID = data.reaction
			value = data.currentStanding
		end
	end

	if not name then return nil end

	local out = { factionName = name, currentStanding = StandingLabel(standingID) }

	if required <= MAX_STANDING then
		out.requiredStanding = StandingLabel(required)
		out.met = standingID ~= nil and standingID >= required or nil
	else
		out.requiredValue = required
		-- Named, not numbered. The index is only a fallback for a threshold that
		-- does not line up with any standing.
		out.requiredStanding = StandingLabel(StandingFromValue(required))
		out.met = value ~= nil and value >= required or nil
	end

	return out
end

-- The normalized shape every display path consumes. Nil fields mean unreadable,
-- never zero and never an invented default.
function ns.ClientSource(sourceID)
	if type(sourceID) ~= "number" then return nil end

	local collection = C_TransmogCollection
	local out = { sourceID = sourceID }

	local info = Try(Fn(collection and collection.GetSourceInfo), sourceID)
	if type(info) == "table" then
		out.itemID = info.itemID
		out.visualID = info.visualID
		out.categoryID = info.categoryID
		out.sourceType = info.sourceType
		out.name = info.name
		out.quality = info.quality
		out.isCollected = info.isCollected
		-- Obtainability. See ns.CanCollect below for why this matters so much.
		out.playerCanCollect = info.playerCanCollect
		out.isValidSourceForPlayer = info.isValidSourceForPlayer
		out.useError = info.useError
	end

	local appearance = ns.AppearanceSourceInfo(sourceID)
	if appearance then
		out.itemLink = out.itemLink or appearance.itemLink
		out.sourceType = out.sourceType or appearance.sourceType
		out.visualID = out.visualID or appearance.visualID
		out.categoryID = out.categoryID or appearance.categoryID
		if out.isCollected == nil then out.isCollected = appearance.isCollected end
	end

	-- One dedicated call exists for the item id, and it is the cheapest path when
	-- the struct above came back empty.
	if not out.itemID then
		out.itemID = Try(Fn(collection and collection.GetSourceItemID), sourceID)
	end

	-- No source type at all means the client has not cached this item yet, which is
	-- the same wall the census counted 1951 times. Nothing here is broken and
	-- nothing is missing from anybody's database: the answer simply has not arrived.
	--
	-- So ask for it and say so. GET_ITEM_INFO_RECEIVED redraws the panel, exactly
	-- as it does for a cost line whose item had no name on the first pass.
	if not out.sourceType and out.itemID then
		-- Two ways to ask, because I cannot confirm the first exists on this build
		-- and betting on it would leave "still fetching" on screen forever.
		--
		-- The second is the universal idiom: calling GetItemInfo on an item the
		-- client has not cached returns nil AND queues the fetch as a side effect.
		-- It has worked that way since the game shipped.
		local request = Fn(C_Item and C_Item.RequestLoadItemDataByID)
		if request then
			Try(request, out.itemID)
			Note("requestRoute", "RequestLoadItemDataByID")
		else
			Try(Fn(GetItemInfo), out.itemID)
			Note("requestRoute", "GetItemInfo side effect")
		end

		Note("lastLoadingItem", out.itemID)

		-- The client is drawing the answer on screen while its own API withholds it.
		-- Reading the label off the tooltip is not elegant, but claiming to know
		-- nothing about a source the player can see described above the panel is
		-- worse. The title is already read from there for the same reason.
		local fromTooltip = ns.TooltipSourceType and ns.TooltipSourceType()
		if fromTooltip then
			out.sourceType = fromTooltip
			out.loading = nil
			Note("typeFromTooltip", fromTooltip)
		else
			out.loading = true
		end
	end

	out.sourceLabel = ns.SourceTypeLabel(out.sourceType)

	local canPlayer, canAccount = ns.CanCollect(sourceID)
	if out.playerCanCollect == nil then out.playerCanCollect = canPlayer end
	out.accountCanCollect = canAccount
	out.drops = Drops(sourceID)
	out.holiday = Try(Fn(collection and collection.GetSourceRequiredHoliday), sourceID)

	if out.itemLink then out.requirements = ns.Requirements(out.itemLink) end

	return out
end

-- Every source behind one visual, which is what a wardrobe button actually
-- represents: several items can share a single appearance.
function ns.SourcesForVisual(visualID)
	local collection = C_TransmogCollection
	local get = Fn(collection and collection.GetAllAppearanceSources)
		or Fn(collection and collection.GetAppearanceSources)
	if not get then return nil end

	local list = Try(get, visualID)
	if type(list) ~= "table" or #list == 0 then return nil end

	local out = {}
	for _, entry in ipairs(list) do
		-- GetAllAppearanceSources answers bare ids, GetAppearanceSources answers
		-- tables carrying one.
		local sourceID = type(entry) == "table" and entry.sourceID or entry
		if type(sourceID) == "number" then out[#out + 1] = sourceID end
	end

	return #out > 0 and out or nil
end
