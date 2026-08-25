local _, ns = ...

--------------------------------------------------------------------------------
-- Wowhead links
--
-- Verified against the live site rather than assumed: the canonical shape is
--
--   https://www.wowhead.com/<flavor>/<locale>/item=<id>
--
-- A locale subdomain such as fr.wowhead.com answers a 301 to that form, so the
-- path is what gets built here. Both segments are omitted when empty, which is
-- how retail and English come out right.
--
-- One hard limit to be honest about: an addon cannot write to the clipboard.
-- There is no API, and there never has been. So a middle click opens a small
-- window with the link already selected, and Control C does the rest. Every
-- addon that offers to "copy" something does exactly this.
--------------------------------------------------------------------------------

local L = ns.L
local Fn = ns.Fn
local Try = ns.Try

--------------------------------------------------------------------------------
-- Which game are we in
--
-- Compared against the WOW_PROJECT constants rather than parsed out of the build
-- string, because the constants are what Blizzard maintains. An unknown project
-- falls through to retail, which is the only sane default: a wrong flavor still
-- lands on a real page.
--------------------------------------------------------------------------------

local function FlavorPath()
	local project = WOW_PROJECT_ID
	if project == nil then return "" end

	if project == WOW_PROJECT_MAINLINE then return "" end
	if project == WOW_PROJECT_CLASSIC then return "classic" end
	if project == WOW_PROJECT_BURNING_CRUSADE_CLASSIC then return "tbc" end
	if project == WOW_PROJECT_WRATH_CLASSIC then return "wotlk" end
	if project == WOW_PROJECT_CATACLYSM_CLASSIC then return "cata" end
	if project == WOW_PROJECT_MISTS_CLASSIC then return "mop-classic" end

	return ""
end

-- Wowhead carries nine languages and names them shorter than the client does.
-- Anything unlisted gets the English page, which is better than a dead link.
local LOCALES = {
	frFR = "fr",
	deDE = "de",
	esES = "es",
	esMX = "es",
	ptBR = "pt",
	ptPT = "pt",
	ruRU = "ru",
	koKR = "ko",
	itIT = "it",
	zhCN = "cn",
	-- No traditional Chinese site exists, and simplified is closer than English.
	zhTW = "cn",
}

local function LocalePath()
	local locale = GetLocale and GetLocale() or nil
	return locale and LOCALES[locale] or ""
end

--------------------------------------------------------------------------------
-- URL building
--------------------------------------------------------------------------------

function ns.WowheadURL(kind, id)
	if type(id) ~= "number" or id <= 0 then return nil end

	local parts = { "https://www.wowhead.com" }

	local flavor = FlavorPath()
	if flavor ~= "" then parts[#parts + 1] = flavor end

	local locale = LocalePath()
	if locale ~= "" then parts[#parts + 1] = locale end

	parts[#parts + 1] = (kind or "item") .. "=" .. id

	return table.concat(parts, "/")
end

--------------------------------------------------------------------------------
-- The copy window
--------------------------------------------------------------------------------

local copyFrame

local function CopyFrame()
	if copyFrame then return copyFrame end

	local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	frame:SetSize(460, 90)
	frame:SetPoint("CENTER")
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

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetText(L.COPY_TITLE)
	frame.title = title

	local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	box:SetPoint("TOPLEFT", 16, -36)
	box:SetSize(424, 24)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetScript("OnEscapePressed", function() frame:Hide() end)
	box:SetScript("OnEnterPressed", function() frame:Hide() end)
	-- Selection is restored on any click inside, so the text cannot be lost by
	-- fumbling the mouse before Control C.
	box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	frame.box = box

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", 16, 12)
	hint:SetText(L.COPY_HINT)

	copyFrame = frame
	return frame
end

function ns.ShowCopy(url)
	if not url then return end

	local frame = CopyFrame()
	frame.box:SetText(url)
	frame:Show()
	frame.box:SetFocus()
	frame.box:HighlightText()
end

-- Called from the tile hook. The item id is the one the panel is displaying, so
-- the link follows Tab like everything else.
function ns.CopyWowheadLink(sourceID)
	local itemID = sourceID and Try(Fn(C_TransmogCollection
		and C_TransmogCollection.GetSourceItemID), sourceID) or nil

	if not itemID then
		local source = sourceID and ns.ClientSource(sourceID) or nil
		itemID = source and source.itemID or nil
	end

	local url = ns.WowheadURL("item", itemID)
	if not url then
		ns.Print(L.COPY_NO_ITEM)
		return
	end

	ns.ShowCopy(url)
end
