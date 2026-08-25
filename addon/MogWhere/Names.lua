local _, ns = ...

--------------------------------------------------------------------------------
-- Creature names
--
-- Earlier versions of this addon refused to resolve an npc name from an id, and
-- said so in several comments, because the only route the client offers is to
-- feed a fabricated "unit:Creature-0-0-0-0-<id>-0" hyperlink into a tooltip, and
-- on this client that prints "Unknown unit" on screen. That is the error spam
-- AllTheThings produces here, and it fires on every uncached name because their
-- lookup sits behind a metatable that resolves lazily and forever.
--
-- Refusing outright was the wrong call. Showing "Orgrimmar" when the useful
-- answer is "Gunra" fails the player to avoid an error message. The middle ground:
--
--   * resolve at most once per creature, never on a hover loop
--   * silence UIErrorsFrame for the length of that single call
--   * write the answer to the saved variables, so it is resolved once ever
--
-- After the first look the name is permanent, and the suppression window is one
-- function call wide rather than a running condition.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

local UNIT_LINK = "unit:Creature-0-0-0-0-%d-0000000000"

--------------------------------------------------------------------------------
-- Retries
--
-- The first call is EXPECTED to miss. Feeding the client a creature id it has
-- never seen starts a fetch, and the tooltip only carries the name once that
-- fetch lands. The first version treated that first miss as permanent and wrote
-- the id off forever, which is why "#36597" stayed on screen: it had asked once,
-- at the only moment the answer could not possibly be ready.
--
-- So a miss schedules another look, a few times, and the panel is redrawn when a
-- name finally arrives. The attempt count is what stops a genuinely bad id from
-- being retried for the rest of the session.
--------------------------------------------------------------------------------

local MAX_ATTEMPTS = 4
local RETRY_DELAY = 0.6

local attempts = {}

local scanner

local function Scanner()
	if scanner then return scanner end
	scanner = CreateFrame("GameTooltip", "MogWhereNameScanner", nil, "GameTooltipTemplate")
	return scanner
end

--------------------------------------------------------------------------------
-- Error suppression
--
-- Narrow on purpose. UIErrorsFrame stops listening, the call happens, it starts
-- listening again. The cost is that a genuine error landing in that same instant
-- is lost, which is a fair trade against a permanent stream of them, and it only
-- ever happens once per creature.
--------------------------------------------------------------------------------

local function Quietly(fn, ...)
	local errors = _G.UIErrorsFrame
	local muted = false

	if errors and errors.UnregisterEvent then
		Try(errors.UnregisterEvent, errors, "UI_ERROR_MESSAGE")
		muted = true
	end

	local a, b = Try(fn, ...)

	if muted and errors.RegisterEvent then
		Try(errors.RegisterEvent, errors, "UI_ERROR_MESSAGE")
	end

	return a, b
end

-- The client answers a placeholder while it fetches, and caching that would
-- freeze "Retrieving data" in place forever.
local function IsPlaceholder(text)
	if type(text) ~= "string" or text == "" then return true end
	local retrieving = _G.RETRIEVING_ITEM_INFO
	if retrieving and text == retrieving then return true end
	return text:find("^Retrieving") ~= nil
end

local function Resolve(npcID)
	local tip = Scanner()
	if not tip then return nil end

	tip:SetOwner(UIParent, "ANCHOR_NONE")
	tip:ClearLines()

	Quietly(tip.SetHyperlink, tip, UNIT_LINK:format(npcID))

	local line = _G["MogWhereNameScannerTextLeft1"]
	local name = line and line.GetText and line:GetText()
	tip:Hide()

	if IsPlaceholder(name) then return nil end
	return name
end

--------------------------------------------------------------------------------

function ns.NPCName(npcID)
	if type(npcID) ~= "number" or npcID <= 0 then return nil end

	-- Ours first, and it is permanent once written.
	local db = ns.db
	if db then
		db.npcNames = db.npcNames or {}
		local known = db.npcNames[npcID]
		if known then return known end
	end

	-- A vendor we have actually stood in front of, which is the most trustworthy
	-- name there is.
	local vendor = db and db.vendors and db.vendors[npcID]
	if vendor and vendor.name then return vendor.name end

	-- Anything AllTheThings has already resolved, read with rawget so their
	-- metatable is never asked to resolve anything on our behalf.
	local att = ns.ATTNPCName and ns.ATTNPCName(npcID)
	if att then
		if db then db.npcNames[npcID] = att end
		return att
	end

	local tries = attempts[npcID] or 0
	if tries >= MAX_ATTEMPTS then return nil end

	attempts[npcID] = tries + 1

	local name = Resolve(npcID)
	if name then
		if db then db.npcNames[npcID] = name end
		return name
	end

	-- Look again shortly, and redraw only if it worked, so a dead id costs a
	-- handful of attempts rather than a permanent loop.
	if C_Timer and C_Timer.After then
		C_Timer.After(RETRY_DELAY, function()
			if ns.NPCName(npcID) then ns.RefreshPanel() end
		end)
	end

	return nil
end

--------------------------------------------------------------------------------
-- Quest titles
--
-- Four routes, because no single one answers for a quest the character has never
-- taken, which is precisely the interesting case. GetTitleForQuestID only knows
-- what the client has loaded, so the load has to be asked for and waited on, the
-- same asynchronous shape as a creature name.
--------------------------------------------------------------------------------

local questAttempts = {}

local function QuestFromTooltip(questID)
	local tip = Scanner()
	if not tip then return nil end

	tip:SetOwner(UIParent, "ANCHOR_NONE")
	tip:ClearLines()
	Quietly(tip.SetHyperlink, tip, "quest:" .. questID)

	local line = _G["MogWhereNameScannerTextLeft1"]
	local text = line and line.GetText and line:GetText()
	tip:Hide()

	if IsPlaceholder(text) then return nil end
	return text
end

function ns.QuestTitle(questID)
	if type(questID) ~= "number" or questID <= 0 then return nil end

	local db = ns.db
	if db then
		db.questNames = db.questNames or {}
		local known = db.questNames[questID]
		if known then return known end
	end

	local log = C_QuestLog
	local title = Try(Fn(log and log.GetTitleForQuestID), questID)
	if not title then title = Try(Fn(log and log.GetQuestInfo), questID) end
	if not title then title = QuestFromTooltip(questID) end

	if type(title) == "string" and title ~= "" and not IsPlaceholder(title) then
		if db then db.questNames[questID] = title end
		return title
	end

	local tries = questAttempts[questID] or 0
	if tries >= MAX_ATTEMPTS then return nil end
	questAttempts[questID] = tries + 1

	-- Ask the client to fetch it, then look again.
	local request = Fn(log and log.RequestLoadQuestByID)
	if request then Try(request, questID) end

	if C_Timer and C_Timer.After then
		C_Timer.After(RETRY_DELAY, function()
			if ns.QuestTitle(questID) then ns.RefreshPanel() end
		end)
	end

	return nil
end
