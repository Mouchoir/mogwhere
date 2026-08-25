local _, ns = ...

--------------------------------------------------------------------------------
-- Optional dependencies
--
-- Neither of these is required to load, and that is deliberate: an addon that
-- refuses to start is worse than one that says less. But the player deserves to
-- know what they are missing rather than wondering why a panel is thin.
--
-- Three states, not two. An addon can be absent, or installed and switched off,
-- and telling someone to download what they already have is its own kind of
-- broken. The second case is a click in the addon list, not a download.
--
-- No link can be opened from an addon, so the URL goes in a selectable box for
-- Control C, exactly as the Wowhead link does.
--------------------------------------------------------------------------------

local L = ns.L
local Fn = ns.Fn
local Try = ns.Try

-- Both URLs were checked against the live site rather than assumed.
local OPTIONAL = {
	{
		addon = "AllTheThings",
		url = "https://www.curseforge.com/wow/addons/all-the-things",
		reason = "DEP_ATT",
	},
	{
		addon = "TomTom",
		url = "https://www.curseforge.com/wow/addons/tomtom",
		reason = "DEP_TOMTOM",
	},
}

--------------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------------

local function State(name)
	if ns.IsLoaded(name) then return "ok" end

	local info = Fn(C_AddOns and C_AddOns.GetAddOnInfo) or Fn(GetAddOnInfo)
	if not info then return "unknown" end

	local _, title, _, loadable, reason = Try(info, name)
	if not title then return "missing" end
	if loadable then return "ok" end
	if reason == "DISABLED" then return "disabled" end

	return "missing"
end

-- Returns only what is actually wrong, so the dialog sizes itself to the problem.
function ns.MissingDependencies()
	local out = {}

	for _, entry in ipairs(OPTIONAL) do
		local state = State(entry.addon)
		if state == "missing" or state == "disabled" then
			out[#out + 1] = {
				addon = entry.addon,
				url = entry.url,
				reason = entry.reason,
				state = state,
			}
		end
	end

	return #out > 0 and out or nil
end

--------------------------------------------------------------------------------
-- The dialog
--------------------------------------------------------------------------------

local dialog

local function Dialog()
	if dialog then return dialog end

	local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	frame:SetWidth(520)
	frame:SetPoint("CENTER", 0, 120)
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

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText(L.DEP_TITLE)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() frame:Hide() end)

	frame.rows = {}
	dialog = frame
	return frame
end

-- One block per missing addon: what it adds, what to do, and the link.
local function Row(index)
	local frame = Dialog()
	if frame.rows[index] then return frame.rows[index] end

	local row = CreateFrame("Frame", nil, frame)
	row:SetSize(488, 62)

	if index == 1 then
		row:SetPoint("TOPLEFT", 16, -46)
	else
		row:SetPoint("TOPLEFT", frame.rows[index - 1], "BOTTOMLEFT", 0, -10)
	end

	local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", 0, 0)
	label:SetWidth(488)
	label:SetJustifyH("LEFT")
	row.label = label

	local note = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
	note:SetWidth(488)
	note:SetJustifyH("LEFT")
	row.note = note

	-- Shown only for an addon that is present but switched off, which is a click
	-- rather than a download. Enabling takes effect on the next UI load, so the
	-- reload is part of the same button instead of a second instruction.
	local enable = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	enable:SetSize(190, 22)
	enable:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 6, -4)
	enable:SetText(L.DEP_ENABLE)
	enable:Hide()
	row.enable = enable

	local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
	box:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 6, -4)
	box:SetSize(470, 22)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	box:Hide()
	row.box = box

	frame.rows[index] = row
	return row
end

function ns.ShowDependencies(missing)
	missing = missing or ns.MissingDependencies()

	local frame = Dialog()
	for _, row in ipairs(frame.rows) do row:Hide() end

	if not missing then
		frame:Hide()
		return false
	end

	for index, entry in ipairs(missing) do
		local row = Row(index)
		row.label:SetText(entry.addon)

		if entry.state == "disabled" then
			row.enable:Show()
			row.enable:SetScript("OnClick", function()
				local on = Fn(C_AddOns and C_AddOns.EnableAddOn)
				if on then Try(on, entry.addon) end
				local reload = Fn(ReloadUI)
				if reload then Try(reload) end
			end)
			row.box:Hide()
		else
			row.enable:Hide()
			row.box:Show()
		end

		-- Disabled means a checkbox in the addon list, not a download, and saying
		-- "install this" to someone who already has it is its own failure.
		row.note:SetText(L[entry.reason] .. " "
			.. (entry.state == "disabled" and L.DEP_DISABLED or L.DEP_MISSING))
		row.box:SetText(entry.url)
		row.box:SetCursorPosition(0)
		row:Show()
	end

	frame:SetHeight(52 + #missing * 72 + 24)
	frame:Show()
	return true
end

--------------------------------------------------------------------------------
-- Shown once, and never again if the player says so
--------------------------------------------------------------------------------

function ns.CheckDependencies()
	local db = ns.db
	if db and db.config and db.config.hideDependencyPrompt then return end

	local missing = ns.MissingDependencies()
	if not missing then return end

	ns.ShowDependencies(missing)

	-- Announced once in chat as well, because a dialog can be dismissed without
	-- being read, and this is the answer to "why is the panel so quiet".
	for _, entry in ipairs(missing) do
		ns.Print(format(L.DEP_CHAT, entry.addon))
	end

	if db and db.config then db.config.hideDependencyPrompt = true end
end
