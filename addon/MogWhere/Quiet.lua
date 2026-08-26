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

	Try(s.SetProfile, s, PROFILE)
	Try(s.ApplyProfile, s)

	-- Checked by reading the result back, not by trusting a return value.
	--
	-- SetProfile returns nothing at all, so the previous version treated "no
	-- return" as failure and refused every single time while having in fact
	-- already switched. Their getter answers "Default" for an unassigned profile,
	-- never nil, which is why the comparison is against the name and not against
	-- truthiness.
	if Try(s.GetProfile, s) ~= PROFILE then return false end

	-- Only now. Every one of these writes into the profile we just switched to.
	for _, key in ipairs(MUTE) do
		Try(s.SetTooltipSetting, s, key, false)
	end

	db.quiet = { active = true, previous = previous }
	return true
end

local function Leave(s, db)
	local previous = db.quiet and db.quiet.previous or nil

	-- nil and "Default" are the same thing to them: SetProfile maps the name back
	-- to nil, and GetProfile reports the name. So the expected outcome has to be
	-- normalised before it can be compared.
	Try(s.SetProfile, s, previous)
	Try(s.ApplyProfile, s)

	local expected = previous or "Default"
	if Try(s.GetProfile, s) ~= expected then return false end

	db.quiet = { active = false, previous = previous }
	return true
end

-- Set, not toggle. "/mw quiet on" run twice must leave the same state as running
-- it once, which a toggle cannot promise, and a script or a macro wants to say
-- what it wants rather than ask for the opposite of whatever holds now.
function ns.SetQuiet(want)
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

	if ns.IsQuiet() == want then
		ns.Print(want and L.QUIET_ALREADY_ON or L.QUIET_ALREADY_OFF)
		return want
	end

	local ok
	if want then
		ok = Enter(s, db)
		if ok then ns.Print(format(L.QUIET_ON, PROFILE)) end
	else
		ok = Leave(s, db)
		if ok then ns.Print(format(L.QUIET_OFF, tostring(db.quiet.previous or "Default"))) end
	end

	if not ok then ns.Print(L.QUIET_FAILED) end
	return ns.IsQuiet()
end

function ns.ToggleQuiet()
	return ns.SetQuiet(not ns.IsQuiet())
end

--------------------------------------------------------------------------------
-- Asking once, the first time AllTheThings is seen
--
-- Neither answer is a sane default. Applying quiet mode unasked would be an addon
-- reconfiguring another one behind the player's back, and doing nothing leaves
-- somebody who installed this for a wardrobe panel wondering why their minimap
-- grew a button.
--
-- So the question gets asked, once, and the answer is remembered. Not asked again
-- on the next character, not asked again after a reload, and reversible from the
-- options panel either way.
--------------------------------------------------------------------------------

-- Laid out downward and measured, not sized by guess.
--
-- The first version fixed the frame at 260 pixels and anchored the buttons to its
-- bottom edge. The body is three paragraphs and wrapped past that, so the buttons
-- sat on top of the last one. Every element is now anchored to the one above it
-- and the height is the sum of what they actually occupy, which cannot go stale
-- when the wording changes or a translation runs longer than the English.
local PAD = 18
local GAP = 14
local WIDTH = 620
local BUTTON_H = 26

local dialog

local function Dialog()
	if dialog then return dialog end

	local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	frame:SetWidth(WIDTH)
	frame:SetPoint("CENTER", 0, 100)
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		frame:SetBackdropColor(0, 0, 0, 0.95)
	end

	local inner = WIDTH - PAD * 2

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", PAD, -PAD)
	title:SetWidth(inner)
	title:SetJustifyH("LEFT")
	title:SetText(L.QUIET_ASK_TITLE)

	local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -GAP)
	body:SetWidth(inner)
	body:SetJustifyH("LEFT")
	body:SetSpacing(3)
	body:SetText(L.QUIET_ASK_BODY)

	-- Answering is mandatory in the sense that closing without choosing would just
	-- ask again next login, so there is no close button and no silent dismissal.
	local keep = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	keep:SetSize((inner - GAP) / 2, BUTTON_H)
	keep:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -GAP - 4)
	keep:SetText(L.QUIET_ASK_KEEP)

	local apply = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	apply:SetSize((inner - GAP) / 2, BUTTON_H)
	apply:SetPoint("TOPRIGHT", body, "BOTTOMRIGHT", 0, -GAP - 4)
	apply:SetText(L.QUIET_ASK_APPLY)

	local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	footer:SetPoint("TOPLEFT", keep, "BOTTOMLEFT", 0, -GAP)
	footer:SetWidth(inner)
	footer:SetJustifyH("CENTER")
	footer:SetText(L.QUIET_ASK_FOOTER)

	frame:SetHeight(PAD + title:GetStringHeight() + GAP + body:GetStringHeight()
		+ GAP + 4 + BUTTON_H + GAP + footer:GetStringHeight() + PAD)

	local function answered()
		local db = ns.db
		if db then
			db.quiet = db.quiet or {}
			db.quiet.asked = true
		end
		frame:Hide()
	end

	-- Both buttons state an outcome, neither guards against the current one.
	--
	-- The apply button used to read "if not already quiet, toggle", which on a
	-- re-ask by somebody who was already quiet did nothing at all and said nothing
	-- either. And "keep it as it is" has to mean the same thing whether it is the
	-- first question or the tenth: AllTheThings showing everything.
	keep:SetScript("OnClick", function()
		answered()
		ns.SetQuiet(false)
	end)

	apply:SetScript("OnClick", function()
		answered()
		ns.SetQuiet(true)
	end)

	dialog = frame
	return frame
end

-- Clears the answer and asks again, right now, with no reload. The dialog is
-- built on demand, so there is nothing to wait for.
function ns.AskQuietAgain()
	local db = ns.db
	if db and db.quiet then db.quiet.asked = nil end
	if not ns.AskQuiet() then ns.Print(L.QUIET_NO_ATT) end
end

function ns.AskQuiet()
	local db = ns.db
	if not db then return false end
	if db.quiet and db.quiet.asked then return false end

	-- Nothing to offer if it is not there, and the question would be nonsense.
	-- The flag is deliberately NOT set here: install ATT next week and the
	-- question is still worth asking then.
	if not ns.HasATT() or not Settings() then return false end

	Dialog():Show()
	return true
end
