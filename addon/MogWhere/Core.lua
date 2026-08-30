local addonName, ns = ...

--------------------------------------------------------------------------------
-- Wiring
--
-- Three layers answer the same question in order of trust: what the client says
-- now, what was harvested from a live merchant, and what AllTheThings knows if it
-- happens to be installed. Nothing here touches GameTooltip, and nothing calls a
-- protected function, so this addon cannot become a link in somebody else's taint
-- chain.
--------------------------------------------------------------------------------

local L = ns.L

local SCHEMA = 1

local frame = CreateFrame("Frame")

--------------------------------------------------------------------------------
-- A cache of client strings has to remember which language it spoke
--
-- Quest titles, creature names and vendor names are all resolved from the client
-- and written to the saved variables so they never have to be fetched twice. That
-- caching was correct and the bug was next to it: nothing recorded the locale
-- those strings came from. Switch the game to English and French quest names keep
-- coming back out of the cache, which looks exactly like a translation failure and
-- is in fact a stale cache.
--
-- Only the names are dropped. Coordinates, prices and stock are the same facts in
-- every language, and throwing away harvested vendor data over a language change
-- would be a real loss for no reason.
--------------------------------------------------------------------------------

local function ForgetForeignLanguage(db)
	local locale = GetLocale and GetLocale() or nil
	if not locale then return end

	if db.cacheLocale == locale then return end
	db.cacheLocale = locale

	db.npcNames = nil
	db.questNames = nil

	for _, vendor in pairs(db.vendors or {}) do
		vendor.name = nil
	end
end

local function InitDB()
	MogWhereDB = MogWhereDB or {}
	local db = MogWhereDB

	db.schema = SCHEMA
	db.vendors = db.vendors or {}

	ForgetForeignLanguage(db)
	db.config = db.config or {}
	if db.config.harvest == nil then db.config.harvest = true end
	-- On by default so it can be judged, and one command away from off.
	if db.config.nameplate == nil then db.config.nameplate = true end

	ns.db = db
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local EVENTS = {
	"ADDON_LOADED", "PLAYER_LOGIN", "MERCHANT_SHOW",
	-- An item name that was not cached at first draw arrives later.
	"GET_ITEM_INFO_RECEIVED",
}

frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == addonName then InitDB() end
		-- The wardrobe frames only exist once Blizzard_Collections is in, which
		-- happens the first time the player opens the Collections journal.
		if arg1 == "Blizzard_Collections" then ns.AttachWardrobe() end
		return
	end

	if event == "PLAYER_LOGIN" then
		if not ns.db then InitDB() end
		-- Another addon may have pulled Collections in already.
		if ns.IsLoaded("Blizzard_Collections") then ns.AttachWardrobe() end

		-- Delayed so it does not land in the middle of the login noise, and so
		-- addons still loading have finished registering.
		-- The panel is registered at login whether or not anything is missing, so
		-- the entry exists in the interface options from the start.
		ns.BuildOptions()

		-- Not delayed, unlike everything below it. This one writes nothing to the
		-- screen and has to beat the first lootable thing in the world, so it goes
		-- out now and retries itself if AllTheThings is not ready yet.
		ns.ReapplyQuiet()

		if C_Timer and C_Timer.After then
			C_Timer.After(8, function() ns.CheckDependencies() end)

			-- Later than the dependency prompt, and mutually exclusive with it in
			-- practice: that one only appears when AllTheThings is missing, this
			-- one only when it is present. The gap is there so a player who is
			-- missing TomTom does not get two dialogs stacked on each other.
			C_Timer.After(13, function() ns.AskQuiet() end)
		end
		return
	end

	if event == "GET_ITEM_INFO_RECEIVED" then
		ns.RefreshPanel()
		return
	end

	if event == "MERCHANT_SHOW" then
		if not ns.db or not ns.db.config.harvest then return end

		-- The inventory is not always fully populated on the very first frame,
		-- so the scan waits a tick rather than reading a half filled window.
		if C_Timer and C_Timer.After then
			C_Timer.After(0.3, function() ns.HarvestMerchant() end)
		else
			ns.HarvestMerchant()
		end
		return
	end
end)

for _, event in ipairs(EVENTS) do
	pcall(frame.RegisterEvent, frame, event)
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function Status()
	local db = ns.db
	if not db then return end

	local vendors, offers = 0, 0
	for _, vendor in pairs(db.vendors or {}) do
		vendors = vendors + 1
		for _ in pairs(vendor.items or {}) do offers = offers + 1 end
	end

	ns.Print(format(L.STATUS_VENDORS, vendors, offers))
	ns.Print(format(L.STATUS_ATT, ns.HasATT() and L.STATUS_ATT_YES or L.STATUS_ATT_NO))
end

local function Help()
	ns.Print(L.HELP_TITLE)
	ns.Print("  /mw probe - " .. L.HELP_PROBE)
	ns.Print("  /mw status - " .. L.HELP_STATUS)
	ns.Print("  /mw census - " .. L.HELP_CENSUS)
	ns.Print("  /mw nameplate - " .. L.HELP_NAMEPLATE)
	ns.Print("  /mw quiet - " .. L.HELP_QUIET)
	ns.Print("      " .. L.HELP_QUIET_ARGS)
	ns.Print("  /mw deps - " .. L.HELP_DEPS)
	ns.Print("  /mw options - " .. L.HELP_OPTIONS)
	ns.Print("  /mw reset - " .. L.HELP_RESET)
end

SLASH_MOGWHERE1 = "/mogwhere"
SLASH_MOGWHERE2 = "/mw"

SlashCmdList.MOGWHERE = function(input)
	local command, argument = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")

	if command == "probe" then
		if ns.Probe() then
			ns.Print(L.PROBE_DONE)
		else
			ns.Print(L.PROBE_NO_UI)
		end
		return
	end

	if command == "reset" then
		if ns.db then
			wipe(ns.db.vendors)
			ns.Print(L.RESET_DONE)
		end
		return
	end

	if command == "status" then
		Status()
		return
	end

	if command == "census" then
		ns.Census()
		return
	end

	if command == "options" or command == "config" then
		ns.OpenOptions()
		return
	end

	if command == "quiet" then
		if argument == "on" then
			ns.SetQuiet(true)
		elseif argument == "off" then
			ns.SetQuiet(false)
		elseif argument == "ask" then
			ns.AskQuietAgain()
		elseif argument == "" then
			ns.ToggleQuiet()
		else
			ns.Print("/mw quiet - " .. L.HELP_QUIET_ARGS)
		end
		return
	end

	if command == "deps" then
		if not ns.ShowDependencies() then ns.Print(L.DEP_NONE) end
		return
	end

	if command == "debug" then
		local db = ns.db
		if db then
			db.config = db.config or {}
			db.config.debug = not db.config.debug
			-- Cleared on the way out, so a stale reading is never mistaken for a
			-- fresh one next time something needs diagnosing.
			if not db.config.debug then db.diag = nil end
			ns.Print(db.config.debug and L.DEBUG_ON or L.DEBUG_OFF)
		end
		return
	end

	if command == "nameplate" then
		local on = ns.ToggleNameplate()
		ns.Print(on and L.NAMEPLATE_ON or L.NAMEPLATE_OFF)
		return
	end

	Help()
end
