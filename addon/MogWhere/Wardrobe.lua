local _, ns = ...

--------------------------------------------------------------------------------
-- Hooking the Appearances tab
--
-- The probe settled the layout: WardrobeCollectionFrame.ItemsCollectionFrame
-- holds exactly 18 entries in .Models, matching the eighteen tiles on screen,
-- and each tile carries GetAppearanceInfo, GetAppearanceLink, OnEnter, OnLeave
-- and OnMouseUp. WardrobeFrame and WardrobeTransmogFrame do not exist here.
--
-- Two things it could not settle, so both are handled defensively:
--
--   1. What GetAppearanceInfo returns. Its visualInfo field came back empty, so
--      the resolver tries four routes in order and records which one won.
--   2. How Blizzard tracks the source that Tab is currently showing. Several
--      visuals share one tile, the client says "press Tab to cycle", and the
--      panel has to follow. GetTooltipSourceIndex exists on both frames, so it
--      is read, and a throttled poll catches the change either way.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

local hooked = false
local HOOK_RETRY_DELAY = 1
local HOOK_MAX_TRIES = 10
local POLL_INTERVAL = 0.15

--------------------------------------------------------------------------------
-- Diagnostics
--
-- Written straight to the saved variable rather than through ns.db. The first
-- version routed it through ns.db and recorded nothing at all while the panel
-- was visibly working, which is a dependency a diagnostic should never have.
--------------------------------------------------------------------------------

local function Debugging()
	return MogWhereDB and MogWhereDB.config and MogWhereDB.config.debug or false
end

local function Note(key, value)
	-- Written only under /mw debug. SourceOf runs on the hover poll, so this would
	-- otherwise fire six times every 150 milliseconds for nobody.
	if not Debugging() then return end
	MogWhereDB = MogWhereDB or {}
	MogWhereDB.diag = MogWhereDB.diag or {}
	MogWhereDB.diag[key] = value
end

--------------------------------------------------------------------------------
-- Resolving a tile into a visual
--------------------------------------------------------------------------------

local function VisualFromField(button)
	local info = button.visualInfo
	if type(info) == "table" and info.visualID then return info.visualID, "visualInfo" end
	if type(button.visualID) == "number" then return button.visualID, "visualID" end
	return nil
end

local function VisualFromInfo(button)
	local first, second = Try(Fn(button.GetAppearanceInfo), button)

	if type(first) == "table" then
		local id = first.visualID or first.itemAppearanceID or first.appearanceID
		if id then return id, "GetAppearanceInfo.table" end
		return nil
	end

	if type(first) == "number" then return first, "GetAppearanceInfo.1" end
	if type(second) == "number" then return second, "GetAppearanceInfo.2" end
	return nil
end

local function VisualFromLink(button)
	local link = Try(Fn(button.GetAppearanceLink), button)
	if type(link) ~= "string" then return nil end
	local id = link:match("transmogappearance:(%d+)") or link:match("transmogillusion:(%d+)")
	if id then return tonumber(id), "GetAppearanceLink" end
	return nil
end

local function VisualOf(button)
	local id, route = VisualFromField(button)
	if id then return id, route end

	id, route = VisualFromInfo(button)
	if id then return id, route end

	return VisualFromLink(button)
end

--------------------------------------------------------------------------------
-- Following Tab
--------------------------------------------------------------------------------

local function ItemsFrame()
	return WardrobeCollectionFrame and WardrobeCollectionFrame.ItemsCollectionFrame or nil
end

--------------------------------------------------------------------------------
-- Blizzard's own ordering, taken from Blizzard rather than reconstructed
--
-- Two attempts at aligning indices were both wrong on screen, so this stops
-- inferring. CollectionWardrobeUtil.SetAppearanceTooltip is the function the
-- client calls to build the very tooltip the player is reading. Hooking it hands
-- over the exact sorted source list it used, and the client then normalises
-- WardrobeCollectionFrame.tooltipSourceIndex against that same list. Reading both
-- is not a guess, it is the client's own answer.
--
-- It also fires again on every Tab press, which is what makes following Tab
-- correct rather than approximate.
--
-- Everything is recorded in diag, because a third wrong guess should be visible
-- in the data instead of on the screen.
--------------------------------------------------------------------------------

local tooltipSources, tooltipVisual

local function HookTooltipBuilder()
	local util = _G.CollectionWardrobeUtil
	if type(util) ~= "table" or type(util.SetAppearanceTooltip) ~= "function" then
		Note("tooltipHook", "SetAppearanceTooltip absent")
		return false
	end

	hooksecurefunc(util, "SetAppearanceTooltip", function(_, sources)
		if type(sources) ~= "table" or #sources == 0 then return end
		tooltipSources = sources
		-- Sources carry their visual, which is how a stale list is detected when
		-- the cursor has already moved to another tile.
		local first = sources[1]
		tooltipVisual = type(first) == "table" and (first.visualID or first.itemAppearanceID) or nil
	end)

	Note("tooltipHook", "hooked")
	return true
end

-- The index the client settled on, read from the field it actually normalises.
local function TooltipIndex()
	local frame = WardrobeCollectionFrame
	if frame and type(frame.tooltipSourceIndex) == "number" and frame.tooltipSourceIndex > 0 then
		return frame.tooltipSourceIndex, "field"
	end

	local items = ItemsFrame()
	local get = items and Fn(items.GetTooltipSourceIndex)
	if get then
		local index = Try(get, items)
		if type(index) == "number" and index > 0 then return index, "items-getter" end
	end

	local outer = frame and Fn(frame.GetTooltipSourceIndex)
	if outer then
		local index = Try(outer, frame)
		if type(index) == "number" and index > 0 then return index, "frame-getter" end
	end

	return nil
end

-- The list Blizzard used, or the sorted utility, or ours as a last resort.
local function SourceList(visualID)
	if tooltipSources and (tooltipVisual == nil or tooltipVisual == visualID) then
		local out = {}
		for index, entry in ipairs(tooltipSources) do
			out[index] = type(entry) == "table" and entry.sourceID or entry
		end
		if #out > 0 then return out, "tooltip-hook" end
	end

	local util = _G.CollectionWardrobeUtil
	local sorted = util and Fn(util.GetSortedAppearanceSources)
	if sorted then
		local list = Try(sorted, visualID)
		if type(list) == "table" and #list > 0 then
			local out = {}
			for index, entry in ipairs(list) do
				out[index] = type(entry) == "table" and entry.sourceID or entry
			end
			return out, "sorted-util"
		end
	end

	-- Reversed on purpose, and only here.
	--
	-- CollectionWardrobeUtil does not exist on this build, so neither the tooltip
	-- hook nor the sorted utility can supply the client's order and this is what is
	-- left. GetAllAppearanceSources hands the list back in the opposite order to
	-- the one the tooltip prints, observed twice: on a four entry appearance the
	-- client's row 1 was this list's row 4, and on a three entry one its row 1 was
	-- row 3.
	--
	-- This is an empirical correction, not a documented contract, which is why it
	-- is confined to the route taken when Blizzard's own sorter is unavailable. It
	-- only ever decides the case where a name AND a source type are both tied, and
	-- being wrong there is no worse than the reversal that was already happening.
	local list = ns.SourcesForVisual(visualID)
	if type(list) ~= "table" or #list < 2 then return list, "unsorted-single" end

	local reversed = {}
	for index = #list, 1, -1 do
		reversed[#reversed + 1] = list[index]
	end

	return reversed, "unsorted-reversed"
end

--------------------------------------------------------------------------------
-- Identity, not position
--
-- Three attempts at index alignment, three wrong answers on screen. The last one
-- was an exact reversal: the arrow on row 1 showed row 4, the arrow on row 4
-- showed row 1. Which means neither CollectionWardrobeUtil route exists on this
-- client and GetAllAppearanceSources hands back the list backwards from the order
-- the tooltip prints.
--
-- So stop counting rows. The tooltip already states which item it is describing,
-- on its first line, and an item name identifies the source without any ordering
-- convention to get wrong. Reading a font string is not a protected call and
-- taints nothing, so this stays clear of the tooltip hook chain that the rest of
-- this addon deliberately avoids.
--------------------------------------------------------------------------------

-- Colour codes and inline textures have to come off before two names can be
-- compared. Locale is not a concern: the tooltip and GetItemNameByID are both the
-- same client answering in the same language, so they agree in all eleven.
local function Plain(text)
	if type(text) ~= "string" then return nil end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("|T.-|t", "")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	return text ~= "" and text or nil
end

local function TooltipTitle()
	local line = _G["GameTooltipTextLeft1"]
	local text = line and line.GetText and line:GetText()
	return Plain(text)
end

-- The source label the client is showing for the item it is describing.
--
-- Not simply line two: that slot is taken by the red "cannot be used by your
-- class" sentence whenever it applies, pushing the label down. So the first few
-- lines are scanned for one that IS a source label, compared against the client's
-- own TRANSMOG_SOURCE strings rather than anything of ours.
local function TooltipSourceLabel()
	local known = {}
	for sourceType = 1, 8 do
		local label = ns.SourceTypeLabel(sourceType)
		if label then known[label] = sourceType end
	end

	for index = 2, 5 do
		local line = _G["GameTooltipTextLeft" .. index]
		local text = Plain(line and line.GetText and line:GetText())

		if text then
			if known[text] then return known[text] end

			-- Matched as a prefix, not by equality.
			--
			-- The line is bare when the client has nothing to add: "Vendor". When it
			-- does have drop details it composes them onto the same line, as in
			-- "Boss Drop: Ji-Kun in Throne of Thunder (10 Player (Heroic), ...)".
			-- Comparing the whole string worked on the simple case and failed on the
			-- informative one, which is how a panel ended up stuck on "still
			-- fetching" for an item the client was describing in full above it.
			local head = text:match("^(.-):")
			if head then
				head = head:gsub("%s+$", "")
				if known[head] then return known[head] end
			end
		end
	end

	return nil
end

-- Exposed so the source layer can fall back on it when GetSourceInfo is silent.
function ns.TooltipSourceType()
	return TooltipSourceLabel()
end

local function NameOf(itemID)
	if type(itemID) ~= "number" then return nil end
	local byID = Fn(C_Item and C_Item.GetItemNameByID)
	local name = byID and Try(byID, itemID) or nil
	if not name then name = Try(Fn(GetItemInfo), itemID) end
	return Plain(name)
end

-- Name first, then the source type as a tie breaker.
--
-- Two entries sharing a name is common, and the first version gave up on the tie
-- and fell through to the index route, which is reversed on this build. That is
-- how a Quest tile ended up reporting "Crafted: Leatherworking": the tie was
-- declared, the fallback ran, and index 1 picked the third entry.
--
-- The client prints the source type alongside the name, so a Quest and a
-- Profession that share a name separate cleanly, with no ordering assumed.
local function MatchByName(sources)
	local title = TooltipTitle()
	if not title or type(sources) ~= "table" then return nil end

	local byName = {}
	for _, sourceID in ipairs(sources) do
		local itemID = Try(Fn(C_TransmogCollection
			and C_TransmogCollection.GetSourceItemID), sourceID)
		if NameOf(itemID) == title then
			byName[#byName + 1] = sourceID
		end
	end

	Note("nameMatches", #byName)
	if #byName == 1 then return byName[1] end
	if #byName == 0 then return nil end

	local wanted = TooltipSourceLabel()
	if not wanted then return nil end

	local narrowed
	local count = 0
	for _, sourceID in ipairs(byName) do
		local info = Try(Fn(C_TransmogCollection
			and C_TransmogCollection.GetSourceInfo), sourceID)
		local sourceType = type(info) == "table" and info.sourceType or nil
		if not sourceType then
			local appearance = ns.AppearanceSourceInfo(sourceID)
			sourceType = appearance and appearance.sourceType or nil
		end
		if sourceType == wanted then
			narrowed = sourceID
			count = count + 1
		end
	end

	Note("typeMatches", count)
	if count == 1 then return narrowed end

	return nil
end

local function SourceOf(button)
	if type(button) ~= "table" then return nil end

	local visualID, route = VisualOf(button)
	if not visualID then
		Note("resolver", "none")
		return nil
	end
	Note("resolver", route)

	-- Tab first, because it is the only route that reflects what the player is
	-- actually looking at when several items share the appearance.
	local sources, listRoute = SourceList(visualID)

	Note("orderRoute", listRoute)
	Note("sourceCount", sources and #sources or 0)

	-- Name first, because it cannot be off by one or reversed.
	local byName = MatchByName(sources)
	if byName then
		Note("tabRoute", "name-match")
		Note("pickedSourceID", byName)
		return byName
	end

	-- Only when the tooltip has not rendered yet, or the item is not cached.
	local index, indexRoute = TooltipIndex()
	Note("indexRoute", indexRoute or "none")
	Note("tooltipIndex", index or "nil")

	if sources and index and sources[index] then
		Note("tabRoute", "index:" .. listRoute .. "+" .. (indexRoute or "?"))
		Note("pickedSourceID", sources[index])
		return sources[index]
	end

	local items = ItemsFrame()
	local chosen = items and Fn(items.GetChosenVisualSource)
	local sourceID = chosen and Try(chosen, items, visualID) or nil

	if type(sourceID) ~= "number" or sourceID <= 0 then
		local fromVisual = items and Fn(items.GetAnAppearanceSourceFromVisual)
		sourceID = fromVisual and Try(fromVisual, items, visualID) or nil
	end

	if type(sourceID) ~= "number" or sourceID <= 0 then
		sourceID = sources and sources[1] or nil
	end

	if not sourceID then
		Note("tabRoute", "no-source")
		return nil
	end

	return sourceID
end

--------------------------------------------------------------------------------
-- Hover tracking
--
-- The poll exists only while a tile is hovered, and does nothing unless the
-- resolved source actually changed, so it costs one comparison per tick.
--------------------------------------------------------------------------------

local watcher = CreateFrame("Frame")
local hovered, shownSource, elapsed = nil, nil, 0

watcher:Hide()
watcher:SetScript("OnUpdate", function(_, delta)
	elapsed = elapsed + delta
	if elapsed < POLL_INTERVAL then return end
	elapsed = 0

	if not hovered then
		watcher:Hide()
		return
	end

	local sourceID = SourceOf(hovered)
	if sourceID ~= shownSource then
		shownSource = sourceID
		ns.ShowFor(sourceID, hovered)
	end
end)

-- Resolve again from the tile, rather than redrawing the same answer.
--
-- The distinction matters. When the item names were not cached, MatchByName found
-- nothing to compare and the index fallback picked a source. Redrawing with that
-- stale id would keep the wrong source forever; asking the tile again lets the
-- name match win now that the names have arrived.
function ns.ReResolveHovered()
	if not hovered then return false end

	local sourceID = SourceOf(hovered)
	shownSource = sourceID
	ns.ShowFor(sourceID, hovered)
	return true
end

local function Enter(button)
	hovered = button
	shownSource = SourceOf(button)
	elapsed = 0
	ns.ShowFor(shownSource, button)
	watcher:Show()
end

local function Leave()
	hovered, shownSource = nil, nil
	watcher:Hide()
	ns.HidePanel()
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local function HookButton(button)
	if not button or button.mogWhereHooked then return end
	button.mogWhereHooked = true

	button:HookScript("OnEnter", function(self) Enter(self) end)
	button:HookScript("OnLeave", Leave)

	-- A modifier is always required. A plain click is how the player previews an
	-- appearance, and dropping a waypoint on every preview would be noise.
	--
	-- Alt, and only Alt. The other two modifiers are already taken by the game:
	-- Shift click links the item in chat, Control click previews the appearance.
	-- Taking either would break something the player already relies on.
	button:HookScript("OnMouseUp", function(_, mouseButton)
		if mouseButton == "MiddleButton" then
			ns.CopyWowheadLink(shownSource)
			return
		end

		if IsAltKeyDown and IsAltKeyDown() then
			ns.DropWaypoint()
		end
	end)
end

local tries = 0

local function Attach()
	if hooked then return true end

	local items = ItemsFrame()
	local models = items and items.Models
	if type(models) ~= "table" or #models == 0 then return false end

	for _, button in ipairs(models) do
		HookButton(button)
	end

	HookTooltipBuilder()

	-- Paging reuses the same eighteen frames, so hooking once is enough and there
	-- is nothing to refresh when the player turns a page.
	hooked = true
	Note("hookedModels", #models)
	return true
end

function ns.AttachWardrobe()
	if Attach() then return end

	tries = tries + 1
	if tries >= HOOK_MAX_TRIES then
		Note("hookedModels", "failed after " .. tries .. " tries")
		return
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(HOOK_RETRY_DELAY, ns.AttachWardrobe)
	end
end
