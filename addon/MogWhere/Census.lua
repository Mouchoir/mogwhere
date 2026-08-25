local _, ns = ...

--------------------------------------------------------------------------------
-- The census
--
-- "Is AllTheThings the right dependency" is not a question worth arguing about,
-- because it reduces to a number nobody has measured: of the appearances you can
-- actually collect, how many can each layer locate.
--
-- The client alone fully answers boss drops, and a world drop has no location to
-- give in the first place, so those two need nothing shipped. Vendors, quests,
-- achievements and professions are the only rows where a dependency earns its
-- keep. If they are a tenth of the wardrobe, ATT should be optional. If they are
-- half, it is load bearing.
--
-- So this walks every category and counts. It runs on a frame budget inside a
-- coroutine, because a fifteen thousand entry walk done in one frame is how you
-- earn a "script ran too long" error.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

local BUDGET_MS = 6
local MAX_CATEGORY = 30

local running

--------------------------------------------------------------------------------
-- Frame budget
--------------------------------------------------------------------------------

local ticker

local function Pump(job)
	if not ticker then
		ticker = CreateFrame("Frame")
	end

	ticker:SetScript("OnUpdate", function()
		if coroutine.status(job) == "dead" then
			ticker:SetScript("OnUpdate", nil)
			running = nil
			return
		end

		local ok, err = coroutine.resume(job)
		if not ok then
			ticker:SetScript("OnUpdate", nil)
			running = nil
			ns.Print(tostring(err))
		end
	end)
end

local function Yield(started)
	if debugprofilestop() - started > BUDGET_MS then
		coroutine.yield()
		return debugprofilestop()
	end
	return started
end

--------------------------------------------------------------------------------
-- The walk
--------------------------------------------------------------------------------

local function CountSource(tally, sourceID)
	local collection = C_TransmogCollection

	local info = Try(Fn(collection and collection.GetSourceInfo), sourceID)
	if type(info) ~= "table" then
		tally.unreadable = tally.unreadable + 1
		return
	end

	-- Counted, never used as a gate. The struct field flagged zero out of 14428.
	-- AccountCanCollectSource flagged 12950 out of 14359, on an account with 599
	-- appearances already collected. Two routes, two absurd answers, so this is
	-- recorded as an observation about the API rather than a fact about the game.
	local _, account = ns.CanCollect(sourceID)
	if account == false then
		tally.accountSaysNo = tally.accountSaysNo + 1
	end

	tally.collectible = tally.collectible + 1

	-- GetSourceInfo leaves sourceType nil until the client has cached the item,
	-- which put 1329 entries in the unreadable column on the first run. The
	-- appearance reader answers it from a different call, so it is asked second
	-- rather than giving up.
	local sourceType = info.sourceType
	if not sourceType then
		local appearance = ns.AppearanceSourceInfo(sourceID)
		sourceType = appearance and appearance.sourceType or nil
		if sourceType then tally.typeRecovered = tally.typeRecovered + 1 end
	end
	sourceType = sourceType or 0
	tally.byType[sourceType] = (tally.byType[sourceType] or 0) + 1

	-- Located by the client on its own.
	local drops = Try(Fn(collection and collection.GetAppearanceSourceDrops), sourceID)
	if type(drops) == "table" and #drops > 0 then
		tally.locatedByClient = tally.locatedByClient + 1
		return
	end

	-- A world drop has no place to send anyone, so it is not a coverage failure.
	if sourceType == 4 then
		tally.worldDrop = tally.worldDrop + 1
		return
	end

	-- Neither is an unreadable source. 1329 entries landed in the gap column of
	-- the first census purely because the client had not cached the item yet,
	-- which is a read to retry, not data that is missing.
	if sourceType == 0 then
		tally.typeUnknown = tally.typeUnknown + 1
		return
	end

	local offers = ns.ATTOffers(info.itemID, sourceID)
	if offers then
		-- A craft is answered, not located, and counting it as a map pin would
		-- flatter the coverage figure.
		for _, offer in ipairs(offers) do
			if offer.recipeName or offer.spellID then
				tally.crafted = tally.crafted + 1
				return
			end
		end
		tally.locatedByATT = tally.locatedByATT + 1
		return
	end

	if ns.HarvestedOffers(info.itemID) then
		tally.locatedByHarvest = tally.locatedByHarvest + 1
		return
	end

	-- The honest number: obtainable, worth locating, and nobody knows where.
	tally.located_by_nobody = tally.located_by_nobody + 1
	tally.gapByType[sourceType] = (tally.gapByType[sourceType] or 0) + 1
end

local function Walk()
	local collection = C_TransmogCollection
	local categories = Fn(collection and collection.GetCategoryAppearances)
	if not categories then
		ns.Print(ns.L.CENSUS_NO_API)
		return
	end

	local tally = {
		visuals = 0,
		collectible = 0,
		notCollectible = 0,
		unreadable = 0,
		locatedByClient = 0,
		locatedByATT = 0,
		locatedByHarvest = 0,
		worldDrop = 0,
		typeUnknown = 0,
		typeRecovered = 0,
		accountSaysNo = 0,
		crafted = 0,
		located_by_nobody = 0,
		byType = {},
		gapByType = {},
		attLoaded = ns.HasATT(),
	}

	local started = debugprofilestop()

	for category = 1, MAX_CATEGORY do
		local appearances = Try(categories, category)
		if type(appearances) == "table" then
			for _, appearance in ipairs(appearances) do
				local visualID = type(appearance) == "table" and appearance.visualID or appearance

				if visualID then
					tally.visuals = tally.visuals + 1

					-- One source per visual. Several items often share an
					-- appearance, and counting each of them would weight the
					-- popular visuals rather than the wardrobe as the player sees
					-- it, which is one tile per visual.
					local sources = ns.SourcesForVisual(visualID)
					if sources and sources[1] then
						CountSource(tally, sources[1])
					end
				end

				started = Yield(started)
			end
		end
		started = Yield(started)
	end

	tally.at = GetServerTime and GetServerTime() or nil

	MogWhereDB = MogWhereDB or {}
	MogWhereDB.census = tally

	ns.ReportCensus(tally)
end

function ns.Census()
	if running then
		ns.Print(ns.L.CENSUS_RUNNING)
		return
	end

	ns.Print(ns.L.CENSUS_START)
	running = coroutine.create(Walk)
	Pump(running)
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

local function Percent(part, whole)
	if not whole or whole == 0 then return 0 end
	return part / whole * 100
end

function ns.ReportCensus(tally)
	local L = ns.L
	local collectible = tally.collectible

	ns.Print(format(L.CENSUS_TOTAL2, tally.visuals, collectible))
	if tally.typeRecovered > 0 then
		ns.Print(format(L.CENSUS_RECOVERED, tally.typeRecovered))
	end
	ns.Print(format(L.CENSUS_ACCOUNT_NOTE, tally.accountSaysNo))

	ns.Print(format(L.CENSUS_CLIENT,
		tally.locatedByClient, Percent(tally.locatedByClient, collectible)))
	ns.Print(format(L.CENSUS_WORLD,
		tally.worldDrop, Percent(tally.worldDrop, collectible)))
	ns.Print(format(L.CENSUS_ATT,
		tally.locatedByATT, Percent(tally.locatedByATT, collectible)))

	if tally.locatedByHarvest > 0 then
		ns.Print(format(L.CENSUS_HARVEST,
			tally.locatedByHarvest, Percent(tally.locatedByHarvest, collectible)))
	end

	ns.Print(format(L.CENSUS_CRAFTED,
		tally.crafted, Percent(tally.crafted, collectible)))
	ns.Print(format(L.CENSUS_UNKNOWN_TYPE,
		tally.typeUnknown, Percent(tally.typeUnknown, collectible)))
	ns.Print(format(L.CENSUS_GAP,
		tally.located_by_nobody, Percent(tally.located_by_nobody, collectible)))

	-- Per source type, so the gap can be attributed rather than lamented.
	for sourceType, count in pairs(tally.gapByType) do
		local label = ns.SourceTypeLabel(sourceType) or tostring(sourceType)
		ns.Print(format(L.CENSUS_GAP_TYPE, label, count))
	end
end
