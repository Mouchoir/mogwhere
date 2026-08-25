local _, ns = ...

--------------------------------------------------------------------------------
-- Options
--
-- The dependency prompt fires once and then never again, which is right for a
-- popup and wrong as the only notice. Somebody who dismissed it on a Tuesday has
-- no way back to the link. So the same information lives here permanently, and
-- keeps saying so until it is actually dealt with rather than until it has been
-- shown once.
--
-- Registered through whichever options API this client carries. The modern
-- Settings namespace and the legacy InterfaceOptions call are both attempted,
-- because a panel nobody can open is not an option panel.
--------------------------------------------------------------------------------

local L = ns.L
local Fn = ns.Fn
local Try = ns.Try

local PANEL_WIDTH = 560

local panel, depLines

--------------------------------------------------------------------------------
-- Small widgets, built by hand
--
-- No template names. InterfaceOptionsCheckButtonTemplate has come and gone across
-- versions, and its label is addressed through a global derived from the frame
-- name, which means naming frames just to write a caption. A separate font string
-- is version proof and shorter.
--------------------------------------------------------------------------------

local function Check(parent, label, anchor, offset, get, set)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetSize(26, 26)
	box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offset or -8)

	local text = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", box, "RIGHT", 2, 1)
	text:SetText(label)

	box:SetChecked(get() and true or false)
	box:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
	end)

	return box
end

--------------------------------------------------------------------------------
-- The dependency block, refreshed every time the panel is shown
--------------------------------------------------------------------------------

local function DepLine(index, anchor)
	depLines = depLines or {}
	if depLines[index] then return depLines[index] end

	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetWidth(PANEL_WIDTH - 40)
	text:SetJustifyH("LEFT")
	text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)

	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 6, -4)
	box:SetSize(PANEL_WIDTH - 60, 22)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

	-- Created hidden. A fresh EditBox is visible by default, and the refresh below
	-- hides every existing line BEFORE creating any new one, so a box built during
	-- that same pass was never hidden by anything. That is how an empty text field
	-- ended up sitting under "both optional addons are present": a link box with no
	-- link in it, for a problem that did not exist.
	box:Hide()
	text:Hide()

	depLines[index] = { text = text, box = box }
	return depLines[index]
end

local function RefreshDependencies(anchor)
	for _, line in ipairs(depLines or {}) do
		line.text:Hide()
		line.box:Hide()
	end

	local missing = ns.MissingDependencies()
	if not missing then
		local line = DepLine(1, anchor)
		line.text:SetText(L.DEP_NONE)
		line.text:Show()
		line.box:Hide()
		return
	end

	local previous = anchor
	for index, entry in ipairs(missing) do
		local line = DepLine(index, previous)
		line.text:SetText(entry.addon .. ": " .. L[entry.reason] .. " "
			.. (entry.state == "disabled" and L.DEP_DISABLED or L.DEP_MISSING))
		line.box:SetText(entry.url)
		line.box:SetCursorPosition(0)
		line.text:Show()
		line.box:Show()
		previous = line.box
	end
end

--------------------------------------------------------------------------------

local function Build()
	if panel then return panel end

	panel = CreateFrame("Frame")
	panel.name = "MogWhere"

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("MogWhere")

	local nameplate = Check(panel, L.OPT_NAMEPLATE, title, -14,
		function()
			local db = ns.db
			return db and db.config and db.config.nameplate ~= false
		end,
		function(value)
			local db = ns.db
			if not db then return end
			db.config = db.config or {}
			db.config.nameplate = value
			if not value then ns.ClearTracked() end
		end)

	local harvest = Check(panel, L.OPT_HARVEST, nameplate, -4,
		function()
			local db = ns.db
			return db and db.config and db.config.harvest ~= false
		end,
		function(value)
			local db = ns.db
			if not db then return end
			db.config = db.config or {}
			db.config.harvest = value
		end)

	local header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header:SetPoint("TOPLEFT", harvest, "BOTTOMLEFT", 0, -20)
	header:SetText(L.OPT_DEPENDENCIES)

	panel:SetScript("OnShow", function() RefreshDependencies(header) end)

	--------------------------------------------------------------------------
	-- Registration, whichever API exists
	--------------------------------------------------------------------------

	local settings = _G.Settings
	local canvas = settings and Fn(settings.RegisterCanvasLayoutCategory)
	local register = settings and Fn(settings.RegisterAddOnCategory)

	if canvas and register then
		local category = Try(canvas, panel, "MogWhere")
		if category then
			panel.settingsCategory = category
			Try(register, category)
			return panel
		end
	end

	local legacy = Fn(_G.InterfaceOptions_AddCategory)
	if legacy then Try(legacy, panel) end

	return panel
end

function ns.BuildOptions()
	return Build()
end

function ns.OpenOptions()
	local built = Build()

	local settings = _G.Settings
	local open = settings and Fn(settings.OpenToCategory)
	if open and built.settingsCategory then
		Try(open, built.settingsCategory:GetID())
		return true
	end

	local legacy = Fn(_G.InterfaceOptionsFrame_OpenToCategory)
	if legacy then
		-- Called twice on purpose. The legacy function is known to land on the
		-- wrong page the first time when the list has never been opened.
		Try(legacy, built)
		Try(legacy, built)
		return true
	end

	return false
end
