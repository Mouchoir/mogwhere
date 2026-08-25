local _, ns = ...

--------------------------------------------------------------------------------
-- API shims
--
-- Two rules, both learned the hard way:
--
-- 1. Existence is tested through Fn, never by truthiness. A table field can hold
--    something that is not callable.
-- 2. Every lookup happens inside the shim, at call time. Nothing is resolved at
--    file load, because on this engine a namespace can be populated after the
--    addon has already been parsed.
--------------------------------------------------------------------------------

function ns.Fn(value)
	if type(value) == "function" then return value end
	return nil
end

local Fn = ns.Fn

-- Any client call can throw on a value the documentation says is safe, so every
-- one of them goes through here and a failure reads as "unreadable".
function ns.Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, f = pcall(fn, ...)
	if not ok then return nil end
	return a, b, c, d, e, f
end

function ns.Print(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(ns.L.PREFIX .. message)
	end
end

--------------------------------------------------------------------------------
-- Addon presence
--------------------------------------------------------------------------------

function ns.IsLoaded(name)
	local loaded = Fn(C_AddOns and C_AddOns.IsAddOnLoaded) or Fn(IsAddOnLoaded)
	if not loaded then return false end
	return ns.Try(loaded, name) and true or false
end

function ns.Load(name)
	if ns.IsLoaded(name) then return true end
	local load = Fn(C_AddOns and C_AddOns.LoadAddOn) or Fn(LoadAddOn)
	if not load then return false end
	ns.Try(load, name)
	return ns.IsLoaded(name)
end

--------------------------------------------------------------------------------
-- Source type labels
--
-- The integers behind Enum.TransmogSource are not worth hardcoding: the client
-- already carries the localized label in TRANSMOG_SOURCE_1 through 6, so reading
-- the global gives the right string in the player's language for free. An
-- unknown value falls back to the number rather than inventing a name.
--------------------------------------------------------------------------------

function ns.SourceTypeLabel(sourceType)
	if type(sourceType) ~= "number" then return nil end
	local label = _G["TRANSMOG_SOURCE_" .. sourceType]
	if type(label) == "string" and label ~= "" then return label end
	return tostring(sourceType)
end

--------------------------------------------------------------------------------
-- Tooltip scanning
--
-- Requirements that live nowhere in the API but do appear in the tooltip text:
-- reputation, required level, required class, bind type. This is a tooltip of
-- our own, never GameTooltip, so nothing here can be caught in somebody else's
-- hook chain.
--
-- Note what this deliberately does NOT do: resolve an NPC name by feeding a
-- fabricated "unit:Creature-0-0-0-0-<id>-0" hyperlink to a tooltip. That trick
-- makes this client shout "Unknown unit" on screen, which is exactly the spam
-- AllTheThings produces on Mists. NPC names come from the live merchant instead.
--------------------------------------------------------------------------------

local scanner

local function Scanner()
	if scanner then return scanner end
	scanner = CreateFrame("GameTooltip", "MogWhereTooltipScanner", nil, "GameTooltipTemplate")
	scanner:SetOwner(UIParent, "ANCHOR_NONE")
	return scanner
end

-- Returns the tooltip as an array of plain lines, left column only.
function ns.TooltipLines(itemLink)
	if type(itemLink) ~= "string" or itemLink == "" then return nil end

	local tip = Scanner()
	if not tip then return nil end

	tip:ClearLines()
	tip:SetOwner(UIParent, "ANCHOR_NONE")
	if not ns.Try(tip.SetHyperlink, tip, itemLink) then return nil end

	local out = {}
	for index = 1, tip:NumLines() do
		local left = _G["MogWhereTooltipScannerTextLeft" .. index]
		local text = left and left:GetText()
		if text and text ~= "" then out[#out + 1] = text end
	end

	return #out > 0 and out or nil
end
