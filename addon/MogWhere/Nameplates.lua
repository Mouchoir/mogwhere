local _, ns = ...

--------------------------------------------------------------------------------
-- Marking the destination
--
-- The ask was a raid marker on the vendor's head. That exact thing is not
-- possible: SetRaidTarget needs a group and assistant rights, so solo it does
-- nothing at all.
--
-- But the star is just a texture, and a nameplate is just a frame. Drawing the
-- icon ourselves gets the same result with no group, no protected call and no
-- marker slot consumed. It is also better behaved: nothing is broadcast to other
-- players and nothing is left behind in a raid's marker assignments.
--
-- It only ever runs while a MogWhere waypoint is active, and it is a setting the
-- player can switch off outright.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local ICON_SIZE = 26

local tracked
local overlays = {}

-- Forward declared: tracking needs to sweep the plates that already exist, and
-- the sweep needs the decorator, which is defined further down.
local Decorate, SweepExisting, StartPolling, StopPolling

local frame = CreateFrame("Frame")

--------------------------------------------------------------------------------
-- Instrumentation
--
-- Two theories about this module have already been wrong on screen. Rather than
-- risk a third, every link in the chain writes what it saw: what was tracked,
-- how many plates the sweep found, how many units were examined, how many
-- matched, and how many were actually decorated. One reload after a reproduction
-- names the broken link instead of inviting another guess.
--------------------------------------------------------------------------------

-- Diagnostics are off unless asked for.
--
-- These counters existed to find one bug, and they found it: the nameplate star
-- was failing on timing, not on logic. Left enabled they would write to the saved
-- variables on every poll tick and every hover tick, several times a second, to
-- record something nobody is reading. So the tooling stays, and stays silent,
-- behind /mw debug.
local function Debugging()
	return MogWhereDB and MogWhereDB.config and MogWhereDB.config.debug or false
end

local function Note(key, value)
	if not Debugging() then return end
	MogWhereDB = MogWhereDB or {}
	MogWhereDB.diag = MogWhereDB.diag or {}
	MogWhereDB.diag["plate_" .. key] = value
end

local function Bump(key)
	if not Debugging() then return end
	MogWhereDB = MogWhereDB or {}
	MogWhereDB.diag = MogWhereDB.diag or {}
	local field = "plate_" .. key
	MogWhereDB.diag[field] = (MogWhereDB.diag[field] or 0) + 1
end

--------------------------------------------------------------------------------
-- The requirement nobody states
--
-- A friendly vendor showing a green name and a title above its head is NOT
-- necessarily wearing a nameplate. The client has two separate systems: the
-- nameplate, which is the health bar frame and the only thing C_NamePlate and
-- NAME_PLATE_UNIT_ADDED know about, and the plain name text, which is drawn by
-- the world and fires no events at all.
--
-- With friendly nameplates switched off, a vendor is perfectly visible and this
-- module never hears about it. That is not a bug to fix in code, it is a setting,
-- so the honest move is to detect it and name the player's own keybind for it
-- rather than leaving a star that silently never appears.
--------------------------------------------------------------------------------

local INTERACTIONS = {
	"MERCHANT_SHOW", "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "TRAINER_SHOW",
}

-- Two lists on purpose, and mixing them would have been a bug of its own making.
--
-- The wide one is only ever dumped for inspection. Deciding from it would read
-- nameplateShowEnemies = 1 and conclude that FRIENDLY plates are on, which is a
-- different setting entirely and would silence the hint on false grounds.
local CVAR_DUMP = {
	"nameplateShowFriends", "nameplateShowFriendlyNPCs", "nameplateShowFriendlyUnits",
	"nameplateShowAll", "nameplateShowEnemies", "nameplateMaxDistance",
	"UnitNameFriendlyPlayerName", "UnitNameNPC",
}

-- Only variables that speak about friendly plates specifically get a vote, and
-- the order matters: nameplateShowFriendlyNPCs is the one this build actually
-- answers. The dump settled that. nameplateShowFriends, the name every guide
-- quotes, is unreadable here, which is exactly why three rounds of guessing at it
-- produced nothing.
local CVAR_FRIENDLY = {
	"nameplateShowFriendlyNPCs", "nameplateShowFriends", "nameplateShowFriendlyUnits",
}

local warned = false

-- Every console variable on this client whose name mentions nameplates, recorded
-- so the guessing can stop. Three candidate names were tried and none answered,
-- which is why the warning never fired and the star failed silently. Whatever
-- this dump contains is the truth about how this build names the setting.
local function DumpPlateCVars()
	local get = Fn(C_CVar and C_CVar.GetCVar) or Fn(GetCVar)
	if not get then return end

	local seen = {}
	for _, name in ipairs(CVAR_DUMP) do
		local value = Try(get, name)
		seen[name] = value ~= nil and tostring(value) or "unreadable"
	end

	MogWhereDB = MogWhereDB or {}
	MogWhereDB.diag = MogWhereDB.diag or {}
	MogWhereDB.diag.plateCVars = seen
end

-- Answers only when it genuinely knows. An unreadable variable means this build
-- names the setting something else, and reporting "off" on that basis would be
-- inventing a fact.
local function FriendlyPlatesOff()
	local get = Fn(C_CVar and C_CVar.GetCVar) or Fn(GetCVar)
	if not get then return nil end

	for _, name in ipairs(CVAR_FRIENDLY) do
		local value = Try(get, name)
		if value == "1" then return false end
		if value == "0" then return true end
	end

	return nil
end

local function WarnOnce()
	if warned then return end
	warned = true

	-- The player's own binding for the friendly nameplate toggle, so the hint names
	-- the key they actually have rather than a default they may have changed.
	local key = Fn(GetBindingKey) and Try(GetBindingKey, "FRIENDNAMEPLATES") or nil
	if not key then
		key = Fn(GetBindingKey) and Try(GetBindingKey, "ALLNAMEPLATES") or nil
	end
	if key then
		ns.Print(format(ns.L.PLATES_OFF_KEY, key))
	else
		ns.Print(ns.L.PLATES_OFF)
	end
end

--------------------------------------------------------------------------------
-- The setting
--------------------------------------------------------------------------------

local function Enabled()
	local db = ns.db
	if not db or not db.config then return false end
	return db.config.nameplate ~= false
end

function ns.ToggleNameplate()
	local db = ns.db
	if not db then return end

	db.config = db.config or {}
	db.config.nameplate = not Enabled()

	if not db.config.nameplate then ns.ClearTracked() end
	return db.config.nameplate
end

--------------------------------------------------------------------------------
-- The overlay
--
-- Nameplates are recycled by the client, so the icon is parented to the plate and
-- hidden rather than created and destroyed on every pull.
--------------------------------------------------------------------------------

local function Overlay(plate)
	if overlays[plate] then return overlays[plate] end

	local holder = CreateFrame("Frame", nil, plate)
	holder:SetSize(ICON_SIZE, ICON_SIZE)
	holder:SetPoint("BOTTOM", plate, "TOP", 0, 4)
	holder:SetFrameStrata("HIGH")

	local icon = holder:CreateTexture(nil, "OVERLAY")
	icon:SetAllPoints(holder)
	icon:SetTexture(STAR)

	holder:Hide()
	overlays[plate] = holder
	return holder
end

local function HideAll()
	for _, holder in pairs(overlays) do
		holder:Hide()
	end
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

-- Matched on creature id, not on name.
--
-- The first version tracked the name, which meant no name meant no star, and an
-- unresolved vendor is exactly the case where a star would help most. A nameplate
-- unit hands over its GUID, and the creature id sits inside it, so the id we
-- already have from AllTheThings is enough on its own. The name is kept only for
-- the chat line.
function ns.TrackNPC(name, npcID)
	if not npcID and not name then return end

	tracked = { name = name, npcID = npcID }

	if not Enabled() then return end

	DumpPlateCVars()

	-- Spoken only when the setting genuinely reads as off. The previous version
	-- warned whenever the state was unknown, which on this build was always, so it
	-- accused the player of a setting they had not changed.
	if FriendlyPlatesOff() == true then WarnOnce() end

	-- Any star left over from the previous errand goes now, before the new one is
	-- placed, so two destinations are never marked at once.
	HideAll()

	frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

	-- Every way a player can actually open a conversation with the thing they
	-- were sent to. Hovering is not one of them, which is the point: the star
	-- stays until the errand is genuinely done.
	for _, event in ipairs(INTERACTIONS) do
		frame:RegisterEvent(event)
	end

	-- The fix for a star that only appeared after toggling nameplates off and on.
	--
	-- NAME_PLATE_UNIT_ADDED fires when a plate is CREATED. Standing next to the
	-- vendor while setting the waypoint means its plate already exists and that
	-- event already happened, before this module was listening. Waiting for it was
	-- waiting for something that had already gone past. Toggling nameplates
	-- destroys and rebuilds every plate, which is why that appeared to fix it.
	--
	-- So the plates already on screen are swept immediately, and the event only
	-- has to cover the ones that show up later.
	Note("trackedName", name or "nil")
	Note("trackedNpcID", npcID or "nil")
	Note("enabled", Enabled())

	SweepExisting()
	StartPolling()
end

function ns.ClearTracked()
	tracked = nil
	StopPolling()
	HideAll()
	frame:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
	frame:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")

	for _, event in ipairs(INTERACTIONS) do
		frame:UnregisterEvent(event)
	end
end

-- Creature-0-<server>-<instance>-<zoneUID>-<creatureID>-<spawnUID>
local function CreatureID(guid)
	if type(guid) ~= "string" then return nil end

	local index = 0
	for part in guid:gmatch("[^-]+") do
		index = index + 1
		if index == 6 then return tonumber(part) end
	end

	return nil
end

local function Matches(unit)
	if not tracked then return false end

	if tracked.npcID then
		local id = CreatureID(Try(Fn(UnitGUID), unit))
		if id and id == tracked.npcID then return true end
	end

	if tracked.name then
		return Try(Fn(UnitName), unit) == tracked.name
	end

	return false
end

--------------------------------------------------------------------------------

function Decorate(unit)
	Bump("decorateCalls")

	if not tracked or not Enabled() then
		Note("lastSkip", "not tracking")
		return
	end

	Note("lastSeenName", Try(Fn(UnitName), unit) or "nil")
	Note("lastSeenID", CreatureID(Try(Fn(UnitGUID), unit)) or "nil")

	if not Matches(unit) then
		Bump("noMatch")
		return
	end

	Bump("matched")

	local plates = C_NamePlate
	local get = Fn(plates and plates.GetNamePlateForUnit)
	if not get then
		Note("lastSkip", "GetNamePlateForUnit absent")
		return
	end

	local plate = Try(get, unit)
	if not plate then
		Note("lastSkip", "no plate for unit")
		return
	end

	Overlay(plate):Show()
	Bump("shown")
	Note("lastSkip", "none")
end

function SweepExisting()
	-- Counted, not accumulated: at one call a second this would otherwise bury the
	-- saved variables in a number nobody reads.
	Note("sweeps", (MogWhereDB and MogWhereDB.diag
		and MogWhereDB.diag.plate_sweeps or 0) + 1)

	local plates = C_NamePlate
	local all = Fn(plates and plates.GetNamePlates)
	if not all then
		Note("getNamePlates", "absent")
		return
	end

	local list = Try(all) or {}
	Note("sweepFound", #list)

	for _, entry in ipairs(list) do
		local unit = type(entry) == "table" and entry.namePlateUnitToken or nil
		if unit then Decorate(unit) end
	end
end

--------------------------------------------------------------------------------
-- Polling, because an event is a moment and a nameplate is a state
--
-- This is the fix, and the previous three were not.
--
-- NAME_PLATE_UNIT_ADDED announces a plate being created, once. Miss that instant
-- and the plate sits there, perfectly present, while this module waits forever
-- for an announcement that has already been made. That is why toggling nameplates
-- appeared to repair things: it destroyed every plate and recreated them, firing
-- the announcements again.
--
-- The measurements said as much. Nineteen units examined, one match, one star
-- shown: the matching and the drawing were never broken. Only the timing was.
--
-- So the plates on screen are now re-examined every second for as long as an
-- errand is active. Nine frames and a table lookup, once a second, is nothing,
-- and it makes the whole class of missed-the-moment failures impossible.
--------------------------------------------------------------------------------

local POLL_INTERVAL = 1
local POLL_LIMIT = 900

local poller, polled

function StartPolling()
	polled = 0

	if not C_Timer or not C_Timer.NewTicker then
		return
	end

	StopPolling()
	poller = C_Timer.NewTicker(POLL_INTERVAL, function()
		polled = polled + POLL_INTERVAL

		-- An errand nobody finished stops costing anything after a while.
		if not tracked or polled > POLL_LIMIT then
			StopPolling()
			return
		end

		SweepExisting()
	end)
end

function StopPolling()
	if poller and poller.Cancel then poller:Cancel() end
	poller = nil
end

local function Undecorate(unit)
	local plates = C_NamePlate
	local get = Fn(plates and plates.GetNamePlateForUnit)
	if not get then return end

	local plate = Try(get, unit)
	local holder = plate and overlays[plate]
	if holder then holder:Hide() end
end

frame:SetScript("OnEvent", function(_, event, unit)
	if event == "NAME_PLATE_UNIT_ADDED" then
		Bump("events")
		Decorate(unit)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		Undecorate(unit)
	elseif tracked and Matches("npc") then
		-- Spoken to. The marker has served its purpose and hanging around would
		-- just be litter on the next pull.
		ns.ClearTracked()
	end
end)
