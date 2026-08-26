local _, ns = ...

--------------------------------------------------------------------------------
-- Quiet mode
--
-- Somebody who installs MogWhere for the wardrobe panel gets the whole of
-- AllTheThings with it: a minimap button, a world map button, tooltip lines under
-- every item, popup windows, sounds. That is a fine addon behaving normally, and
-- it is also not what they asked for.
--
-- So: one switch that silences it, and one that gives it back exactly as it was.
--
-- The dangerous way to do that is to remember every setting, overwrite them, and
-- hope the restore runs. A crash, a reload at the wrong moment or an uninstall
-- and the player is left with a half configured addon and no idea why.
--
-- ATT has profiles, so none of that is necessary. Quiet mode copies the player's
-- current profile into one named "MogWhere", switches to it, and only THEN mutes
-- anything. Every write lands in our profile. Theirs is never touched, is still
-- listed in ATT's own settings, and switching back is one call rather than a
-- replay of thirty values. Worst case, the player picks their profile again from
-- ATT's own interface without us being involved at all.
--------------------------------------------------------------------------------

local L = ns.L
local Try = ns.Try

local PROFILE = "MogWhere"

-- Everything ATT puts on screen or in chat that a MogWhere user did not ask for.
-- Anything absent from a given build is simply ignored, which is why this is a
-- flat list rather than a version matrix.
local MUTE = {
	"Enabled",                -- the tooltip lines under every item
	"MinimapButton",
	"WorldMapButton",
	"Models",
	"Celebrate",
	"Screenshot",
	"Auto:MiniList",
	"Auto:AuctionList",
	"Auto:ProfessionList",
	"Show:TooltipHelp",
	"SourceLocations",
	"Warn:Removed",
}

local function Settings()
	local app = _G.ATTC or _G.AllTheThings
	local s = type(app) == "table" and app.Settings or nil
	if type(s) ~= "table" then return nil end
	-- Every call used below, checked before any of them runs. A half applied
	-- profile switch is worse than a button that politely does nothing.
	for _, name in ipairs({ "GetProfile", "SetProfile", "CopyProfile",
		"ApplyProfile", "SetTooltipSetting" }) do
		if type(s[name]) ~= "function" then return nil end
	end
	return s
end

function ns.IsQuiet()
	local db = ns.db
	return db and db.quiet and db.quiet.active or false
end

--------------------------------------------------------------------------------

local function Enter(s, db)
	local previous = Try(s.GetProfile, s)

	-- Already ours means a previous session ended without restoring. Keep the
	-- profile we remembered rather than recording "MogWhere" as the thing to
	-- return to, which would strand the player in quiet mode permanently.
	if previous == PROFILE then
		previous = db.quiet and db.quiet.previous or nil
	end

	-- A fresh copy every time, so a player who changed an ATT setting and then
	-- switched quiet mode on gets that change carried over rather than a stale
	-- snapshot from last week.
	Try(s.CopyProfile, s, PROFILE, previous)

	if not Try(s.SetProfile, s, PROFILE) then return false end
	Try(s.ApplyProfile, s)

	-- Only now. Every one of these writes into the profile we just switched to.
	for _, key in ipairs(MUTE) do
		Try(s.SetTooltipSetting, s, key, false)
	end

	db.quiet = { active = true, previous = previous }
	return true
end

local function Leave(s, db)
	local previous = db.quiet and db.quiet.previous or nil

	-- nil is Default, which is what ATT itself uses for the unnamed profile.
	Try(s.SetProfile, s, previous)
	Try(s.ApplyProfile, s)

	db.quiet = { active = false, previous = previous }
	return true
end

function ns.ToggleQuiet()
	local db = ns.db
	if not db then return nil end

	if not ns.HasATT() then
		ns.Print(L.QUIET_NO_ATT)
		return nil
	end

	local s = Settings()
	if not s then
		ns.Print(L.QUIET_NO_API)
		return nil
	end

	local ok
	if ns.IsQuiet() then
		ok = Leave(s, db)
		if ok then ns.Print(format(L.QUIET_OFF, tostring(db.quiet.previous or "Default"))) end
	else
		ok = Enter(s, db)
		if ok then ns.Print(format(L.QUIET_ON, PROFILE)) end
	end

	if not ok then ns.Print(L.QUIET_FAILED) end
	return ns.IsQuiet()
end
