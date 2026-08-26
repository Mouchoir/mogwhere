local _, ns = ...

--------------------------------------------------------------------------------
-- The panel
--
-- A frame of our own, anchored to the wardrobe tile under the cursor. Never
-- GameTooltip. The Appearances tab is already crowded with addons hooking that
-- tooltip, and this client has a live taint chain running through it, so joining
-- that queue would make us a link in it.
--
-- Deliberately not mouse enabled. Moving the cursor onto the panel would leave
-- the tile, the tile would fire OnLeave, and the panel would vanish under the
-- pointer. So the panel only ever explains, and every click is taken on the tile
-- itself.
--
-- Nothing here invents a translation. Instance names, difficulties, faction
-- names and the class error sentence all come from the client already localized,
-- and our own wording lives in Locale.lua with enUS as the fallback for every
-- language we have not written out yet.
--------------------------------------------------------------------------------

local L = ns.L
local Fn = ns.Fn
local Try = ns.Try

local PANEL_WIDTH = 340
local PANEL_PADDING = 12
local LINE_SPACING = 3
local MAX_CRITERIA_SHOWN = 8

local panel, lines
local used = 0

--------------------------------------------------------------------------------
-- Frame construction
--------------------------------------------------------------------------------

local function Panel()
	if panel then return panel end

	panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	panel:SetFrameStrata("TOOLTIP")
	panel:SetWidth(PANEL_WIDTH)
	panel:Hide()

	if panel.SetBackdrop then
		panel:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		panel:SetBackdropColor(0, 0, 0, 0.9)
	end

	lines = {}
	return panel
end

local function Line(index)
	local frame = Panel()
	if lines[index] then return lines[index] end

	local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	text:SetWidth(PANEL_WIDTH - PANEL_PADDING * 2)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(true)

	if index == 1 then
		text:SetPoint("TOPLEFT", frame, "TOPLEFT", PANEL_PADDING, -PANEL_PADDING)
	else
		text:SetPoint("TOPLEFT", lines[index - 1], "BOTTOMLEFT", 0, -LINE_SPACING)
	end

	lines[index] = text
	return text
end

local function Reset()
	used = 0
	for _, text in ipairs(lines or {}) do
		text:SetText("")
		text:Hide()
	end
end

local function Add(text, r, g, b)
	if not text or text == "" then return end
	used = used + 1
	local line = Line(used)
	line:SetText(text)
	line:SetTextColor(r or 1, g or 1, b or 1)
	line:Show()
end

local function Finish(anchorTo)
	local frame = Panel()
	if used == 0 or not anchorTo then
		frame:Hide()
		return
	end

	local height = PANEL_PADDING * 2
	for index = 1, used do
		height = height + lines[index]:GetStringHeight() + LINE_SPACING
	end
	frame:SetHeight(height)

	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", anchorTo, "TOPRIGHT", 8, 0)
	frame:Show()
end

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

-- Printing "#64314" is worse than printing nothing: it looks like a defect and it
-- tells the player nothing. The client simply has not cached that item yet, so
-- the fix is to ask it to, and to redraw when it answers. See ns.RefreshPanel.
local function ItemName(itemID)
	if type(itemID) ~= "number" then return nil end

	local byID = Fn(C_Item and C_Item.GetItemNameByID)
	local name = byID and Try(byID, itemID) or nil
	if not name then name = Try(Fn(GetItemInfo), itemID) end
	if name then return name end

	local request = Fn(C_Item and C_Item.RequestLoadItemDataByID)
	if request then Try(request, itemID) end
	return nil
end

local function CurrencyName(currencyID)
	local info = Try(Fn(C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo), currencyID)
	return type(info) == "table" and info.name or nil
end

local function CostText(cost)
	if cost.kind == "gold" then
		local money = Fn(GetCoinTextureString)
		local amount = money and Try(money, cost.amount) or tostring(cost.amount)
		return format(L.COST_GOLD, amount)
	end

	if cost.kind == "item" then
		local name = ItemName(cost.itemID)
		if not name then return nil end
		return format(L.COST_ITEM, cost.quantity or 1, name)
	end

	if cost.kind == "currency" then
		local name = cost.currencyName or CurrencyName(cost.currencyID)
		if not name then return nil end
		return format(L.COST_CURRENCY, cost.quantity or 1, name)
	end

	return nil
end

-- Every difficulty, not the first one. The client says a Blackwing Descent helm
-- drops on 10 and 25 player, and reporting only one of the two is a lie by
-- omission that sends the player into the wrong raid size.
local function DifficultyText(list)
	if type(list) ~= "table" or #list == 0 then return nil end
	return table.concat(list, L.DIFFICULTY_SEPARATOR)
end

--------------------------------------------------------------------------------
-- Waypoints
--
-- A quest handed out in Ironforge for one side and Orgrimmar for the other has
-- two answers, so the panel keeps one per side and the modifier picks. Control
-- takes Alliance, Shift takes Horde, and the waypoint title carries the letter
-- so a route left on the map stays readable an hour later.
--------------------------------------------------------------------------------

local waypoints = {}
local waypointSubject

local function ClearWaypoints()
	waypoints = { Alliance = nil, Horde = nil, any = nil, count = 0 }
end

local function RememberWaypoint(offer)
	if not offer or not offer.mapID or not offer.x then return false end

	local side = offer.faction
	if side and not waypoints[side] then
		waypoints[side] = offer
		waypoints.count = (waypoints.count or 0) + 1
	elseif not waypoints.any then
		waypoints.any = offer
		waypoints.count = (waypoints.count or 0) + 1
	end

	return true
end

--------------------------------------------------------------------------------
-- Why the arrow sometimes does nothing
--
-- Read straight out of TomTom's own TomTom_Waypoints.lua:
--
--   local x, y, instance = hbd:GetPlayerWorldPosition()
--   local pointX, pointY, pointInstance = hbd:GetWorldCoordinatesFromZone(...)
--   if instance ~= pointInstance then return end
--
-- It returns nothing at all when the player is not on the same world instance as
-- the destination. So a waypoint on Orgrimmar, set while standing in Pandaria, is
-- stored and drawn on the world map but the arrow gives no bearing and no
-- distance until you arrive on that continent.
--
-- That is TomTom behaving sensibly, there is no useful heading across an ocean.
-- But an arrow that silently does nothing reads as a broken addon, so the panel
-- says so before the player clicks.
--------------------------------------------------------------------------------

local function ContinentOf(mapID)
	if type(mapID) ~= "number" then return nil end

	local info = Try(Fn(C_Map and C_Map.GetMapInfo), mapID)
	local continent = Enum and Enum.UIMapType and Enum.UIMapType.Continent

	local guard = 0
	while type(info) == "table" and guard < 12 do
		if continent and info.mapType == continent then return info.mapID, info.name end
		if not info.parentMapID or info.parentMapID == 0 then break end
		info = Try(Fn(C_Map and C_Map.GetMapInfo), info.parentMapID)
		guard = guard + 1
	end

	return nil
end

-- True when the arrow will stay mute, which is the only case worth mentioning.
local function IsFarAway(offer)
	if not offer or not offer.mapID then return false end

	local here = Try(Fn(C_Map and C_Map.GetBestMapForUnit), "player")
	if not here then return false end

	local hereContinent = ContinentOf(here)
	local thereContinent, thereName = ContinentOf(offer.mapID)
	if not hereContinent or not thereContinent then return false end

	if hereContinent == thereContinent then return false end
	return true, thereName
end

-- "Alliance" and "Horde" from UnitFactionGroup are locale independent tokens, so
-- they can be compared. The display name always comes from the client globals.
local function OwnFaction()
	local group = Try(Fn(UnitFactionGroup), "player")
	if group == "Alliance" or group == "Horde" then return group end
	return nil
end

local function ShortTag(side)
	if side == "Alliance" then return "A" end
	if side == "Horde" then return "H" end
	return nil
end

--------------------------------------------------------------------------------
-- Re-arming the arrow on arrival
--
-- TomTom says it plainly in its own comment: the distance cannot be computed when
-- the waypoint is on another continent, and in that case it calls Hide on the
-- arrow frame. The catch is that the OnUpdate which would notice your arrival is
-- attached to that very frame, and a hidden frame does not run OnUpdate. So the
-- arrow goes away over an ocean and never comes back on its own, which is exactly
-- what happens when a waypoint is set from Orgrimmar and used in the Blasted
-- Lands: the pin is on the map, the arrow is gone for good.
--
-- Setting the crazy arrow again once the continent matches is all it takes. This
-- is not a workaround for a TomTom bug, it is the call TomTom expects somebody to
-- make when the situation changes.
--------------------------------------------------------------------------------

local pendingArrow
local rearmer = CreateFrame("Frame")

local ARRIVE_DISTANCE = 15

local function Rearm()
	if not pendingArrow or not pendingArrow.uid then return end
	if type(TomTom) ~= "table" then return end

	-- Still an ocean away: keep waiting rather than pointing at nothing.
	if IsFarAway({ mapID = pendingArrow.mapID }) then return end

	local set = Fn(TomTom.SetCrazyArrow)
	if set then Try(set, TomTom, pendingArrow.uid, ARRIVE_DISTANCE, pendingArrow.title) end

	pendingArrow = nil
	rearmer:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
	rearmer:UnregisterEvent("PLAYER_ENTERING_WORLD")
end

rearmer:SetScript("OnEvent", function()
	-- A zone change lands before the map data settles, so the check waits a beat.
	if C_Timer and C_Timer.After then
		C_Timer.After(2, Rearm)
	else
		Rearm()
	end
end)

-- What the star should sit on for this offer.
--
-- A vendor or a quest giver is somebody to walk up to. A drop is something to
-- kill, and until now only recipe drops carried a creature id, so a rare holding
-- the appearance itself was never marked at all.
local function TargetOf(offer)
	if offer.npcID then return offer.npcID end
	local kills = offer.creatures
	if type(kills) == "table" and kills[1] then return kills[1] end
	return nil
end

function ns.DropWaypoint()
	-- The player has one faction, and a waypoint to the other side's vendor is
	-- something they can never walk to. So there is no side to choose: take our
	-- own, and fall back to whatever single location we have.
	--
	-- This replaces a Control and Alt split that was over-engineered on my part,
	-- and wrong twice over: Control click already previews the appearance, and
	-- Shift click already links the item in chat. Alt was the only key left, and
	-- one key is all this ever needed.
	local own = OwnFaction()
	local offer = (own and waypoints[own]) or waypoints.any
		or waypoints.Alliance or waypoints.Horde

	if not offer then return end

	if type(TomTom) ~= "table" or type(TomTom.AddWaypoint) ~= "function" then
		ns.Print(L.WAYPOINT_NO_TOMTOM)
		return
	end

	-- What to read on the arrow, in order of usefulness: who to talk to, why you
	-- are going, and only then where. The zone was the first fallback and it is
	-- the least useful of the three, since it names the place you are standing in
	-- by the time the arrow is guiding you.
	local title = offer.npcName or offer.questName or offer.recipeName
		or waypointSubject or offer.zone or "MogWhere"
	local tag = ShortTag(offer.faction)
	if tag then title = title .. " (" .. tag .. ")" end

	-- Only the title is passed. crazy, minimap, world and persistent are all
	-- deliberately left out so TomTom applies the settings the player chose in
	-- TomTom, instead of this addon deciding whether they get an arrow.
	local uid = Try(TomTom.AddWaypoint, TomTom, offer.mapID, offer.x / 100, offer.y / 100,
		{ title = title, from = "MogWhere" })

	-- Said at the moment of the click, not only in the panel. A player who has
	-- already looked away and is watching chat gets no arrow and no explanation
	-- otherwise, which reads as a waypoint that failed to register.
	local far, continent = IsFarAway(offer)
	if far then
		ns.Print(format(L.WAYPOINT_FAR, offer.zone or continent or "?"))
		-- Remembered so the arrow can be re-armed on arrival. See Rearm below.
		pendingArrow = { uid = uid, title = title, mapID = offer.mapID }
		rearmer:RegisterEvent("ZONE_CHANGED_NEW_AREA")
		rearmer:RegisterEvent("PLAYER_ENTERING_WORLD")
	else
		pendingArrow = nil
	end

	-- Only now, because the star is meant to appear while you are travelling to a
	-- destination you asked for, not on every hover.
	ns.TrackNPC(offer.npcName, TargetOf(offer))

	ns.Print(format(L.WAYPOINT_READY, title))
end

--------------------------------------------------------------------------------
-- Collectibility, or rather the absence of it
--
-- Three versions of this section made three different claims, and the census
-- killed all three. Reading info.accountCanCollect off the struct flagged zero
-- appearances out of fourteen thousand, because the field is nil here. Reading
-- AccountCanCollectSource instead flagged 12950 of 14359 as unobtainable, on an
-- account with 599 appearances already collected. Both numbers are absurd, in
-- opposite directions.
--
-- So the conclusion is that this client does not answer "can this be obtained"
-- through either route, and the honest thing is to stop pretending it does. No
-- line here gates the display any more.
--
-- What survives is what the client actually authors: whether it is already
-- collected, and useError, which is a finished sentence written by Blizzard about
-- this character and this appearance.
--------------------------------------------------------------------------------

local function AddStatus(source)
	if source.isCollected then Add(L.COLLECTED) end
end

local function AddDrops(source)
	if not source.drops then return false end

	for _, drop in ipairs(source.drops) do
		local difficulty = DifficultyText(drop.difficulties)
		if drop.instance and drop.encounter and difficulty then
			Add(format(L.DROP_DIFFICULTY, drop.instance, drop.encounter, difficulty), 1, 0.82, 0)
		elseif drop.instance and drop.encounter then
			Add(format(L.DROP_LINE, drop.instance, drop.encounter), 1, 0.82, 0)
		elseif drop.instance then
			Add(drop.instance, 1, 0.82, 0)
		end
	end

	return true
end

-- Shown, but marked, rather than dropped.
--
-- Dropping it outright produced a real misreading: an appearance with an Alliance
-- quest and a Horde quest showed full detail on one Tab entry and "no location on
-- record" on the other, as though the data were missing. It was not missing, it
-- was filtered. "Not for your side" and "nobody knows" are completely different
-- answers and the panel was giving the wrong one.
--
-- So the other side is printed dimmed and named, and it never claims a waypoint.
local function OtherSide(offer, own)
	return offer.faction ~= nil and own ~= nil and offer.faction ~= own
end

--------------------------------------------------------------------------------
-- One branch per source type
--
-- The previous version chose its wording from whichever field happened to be
-- filled, and printed "sold by the Lich King" on a quest reward because a name
-- existed and it assumed a vendor. The label now follows sourceType, which is the
-- client stating what kind of source this is, and nothing else gets a vote.
--------------------------------------------------------------------------------

local SOURCE_DROP = 1
local SOURCE_QUEST = 2
local SOURCE_VENDOR = 3
local SOURCE_ACHIEVEMENT = 5
local SOURCE_PROFESSION = 6

-- What to call the thing in a sentence, so a missing dependency can be explained
-- in terms of what the reader is looking at rather than in the abstract.
local NOUNS = {
	[SOURCE_DROP] = "NOUN_DROP",
	[SOURCE_QUEST] = "NOUN_QUEST",
	[SOURCE_VENDOR] = "NOUN_VENDOR",
	[SOURCE_ACHIEVEMENT] = "NOUN_ACHIEVEMENT",
	[SOURCE_PROFESSION] = "NOUN_RECIPE",
}

local function Noun(sourceType)
	return L[NOUNS[sourceType] or "NOUN_DEFAULT"]
end

-- Instance, boss, difficulty, and the header their tree filed it under. Printed
-- in that order and only when known, so a raid item reads "Siege of Orgrimmar,
-- Shared Loot" instead of nothing at all.
local function AddPlace(offer)
	local place = offer.instanceName
	if place and offer.encounterName then
		place = format(L.DROP_LINE, place, offer.encounterName)
	end

	if place then
		if offer.difficultyName then
			Add(format(L.PLACE_DIFFICULTY, place, offer.difficultyName), 1, 0.82, 0)
		else
			Add(place, 1, 0.82, 0)
		end
	end

	-- The header is the shelf their database used, which is often the only clue
	-- for loot that hangs off no encounter at all.
	if offer.headerName and offer.headerName ~= place then
		Add(offer.headerName, 0.8, 0.8, 0.8)
	end
end

local function AddReputation(offer)
	local gate = ns.ReputationGate(offer.minReputation)
	if not gate then return end

	local requirement = gate.requiredStanding
		or (gate.requiredValue and tostring(gate.requiredValue))
	if not requirement then return end

	if gate.met then
		Add(format(L.REP_MET, requirement, gate.factionName), 0.4, 1, 0.4)
	elseif gate.currentStanding then
		Add(format(L.REP_SHORT, requirement, gate.factionName, gate.currentStanding),
			1, 0.4, 0.4)
	else
		Add(format(L.REQUIRES_REPUTATION, gate.factionName, requirement), 1, 0.4, 0.4)
	end
end

local function AddAchievement(offer, suffix)
	local detail = ns.AchievementDetail(offer.achievementID)
	if not detail then return end

	Add(format(L.ACHIEVEMENT_NAMED, detail.name) .. suffix, 1, 0.82, 0)
	if detail.description then Add(detail.description, 0.75, 0.75, 0.75) end

	if detail.completed then
		Add(L.ACHIEVEMENT_DONE)
		return
	end

	if not detail.criteriaTotal then return end

	Add(format(L.ACHIEVEMENT_PROGRESS, detail.criteriaDone, detail.criteriaTotal),
		0.6, 0.85, 1)

	-- What is left, not what is done. Capped, because an exploration achievement
	-- can carry forty criteria and a panel that tall stops being readable.
	for index, text in ipairs(detail.missing or {}) do
		if index > MAX_CRITERIA_SHOWN then
			Add(format(L.ACHIEVEMENT_MORE, #detail.missing - MAX_CRITERIA_SHOWN),
				0.5, 0.5, 0.5)
			break
		end
		Add(format(L.CRITERION_MISSING, text), 0.85, 0.7, 0.55)
	end
end

local function AddCraft(offer, suffix)
	Add(format(L.CRAFTED_BY, offer.recipeName or "?") .. suffix, 1, 0.82, 0)

	if offer.learnedAt then
		Add(format(L.CRAFTED_AT_LEVEL, offer.learnedAt), 0.8, 0.8, 0.8)
	end

	-- Where the recipe itself comes from. A creature name is something a player
	-- can target and hunt; the word "drop" is not.
	--
	-- Note what is deliberately not claimed: nothing says "boss" or "rare". The
	-- data carries creature ids, not a classification, and inventing one would be
	-- a guess dressed as a fact.
	local kills = offer.recipeDroppedBy
	if type(kills) == "table" and #kills > 0 then
		local name = ns.NPCName(kills[1])
		if name and #kills == 1 then
			Add(format(L.RECIPE_DROPPED_BY, name), 0.9, 0.7, 0.7)
		elseif name then
			Add(format(L.RECIPE_DROPPED_BY_MANY, name, #kills - 1), 0.9, 0.7, 0.7)
		else
			Add(L.RECIPE_FROM_KILL, 0.9, 0.7, 0.7)
		end
	end
end

local function AddQuest(offer, suffix)
	if offer.questName then
		Add(format(L.QUEST_NAMED, offer.questName) .. suffix, 1, 0.82, 0)
	else
		Add(L.QUEST_UNNAMED .. suffix, 1, 0.82, 0)
	end

	if offer.questGiverName then
		Add(format(L.QUEST_GIVER, offer.questGiverName), 0.8, 0.8, 0.8)
	elseif offer.questGiverID then
		Add(format(L.QUEST_GIVER, format(L.QUEST_GIVER_UNKNOWN, offer.questGiverID)),
			0.8, 0.8, 0.8)
	end
end

--------------------------------------------------------------------------------
-- The version you can actually do
--
-- "This one is for the other side" is only half an answer. The appearance almost
-- always has a twin, and telling the player which sibling is theirs saves them
-- pressing Tab and guessing. The sources of one visual are already known, so this
-- is a lookup rather than new data.
--------------------------------------------------------------------------------

local function Equivalent(source)
	local own = OwnFaction()
	if not own or not source.visualID then return nil end

	local siblings = ns.SourcesForVisual(source.visualID)
	if not siblings then return nil end

	for _, sourceID in ipairs(siblings) do
		if sourceID ~= source.sourceID then
			local sibling = ns.ClientSource(sourceID)
			for _, offer in ipairs(sibling and ns.Offers(sibling.itemID, sourceID) or {}) do
				if offer.faction == own then
					return offer
				end
			end
		end
	end

	return nil
end

local function AddOffer(source, offer)
	-- The other side keeps its label, because that is the whole point of showing
	-- it: the reader has to know why this one is not for them.
	local suffix = offer.otherFaction and offer.factionName
		and (" |cff808080(" .. offer.factionName .. ")|r") or ""
	local kind = source.sourceType

	if offer.achievementID then
		AddAchievement(offer, suffix)
	elseif kind == SOURCE_PROFESSION or offer.recipeName then
		AddCraft(offer, suffix)
	elseif kind == SOURCE_QUEST then
		AddQuest(offer, suffix)
	elseif kind == SOURCE_VENDOR then
		if offer.npcName then
			Add(format(L.SOURCE_VENDOR, offer.npcName) .. suffix, 1, 0.82, 0)
		else
			Add(L.SOURCE_VENDOR_UNKNOWN .. suffix, 1, 0.82, 0)
		end
	end

	-- Where it lives, whatever the source type. This is generic on purpose: any
	-- offer that came out of a hierarchy can name that hierarchy, and the boss drop
	-- that the Encounter Journal has never heard of is only the case that made the
	-- omission visible.
	AddPlace(offer)
	AddReputation(offer)

	if offer.zone and offer.x and offer.y then
		Add(format(L.AT_ZONE, offer.zone, offer.x, offer.y), 0.6, 0.85, 1)
	elseif offer.zone then
		Add(offer.zone, 0.6, 0.85, 1)
	end

	for _, cost in ipairs(offer.costs or {}) do
		local text = CostText(cost)
		if text then Add(text, 0.8, 0.8, 0.8) end
	end

	-- The other side is informative, never navigable: no waypoint is registered for
	-- a vendor the player can never walk up to.
	if offer.otherFaction then
		Add(format(L.OTHER_FACTION_IS, offer.factionName or "?"), 1, 0.3, 0.3)

		-- And where to go instead.
		local mine = Equivalent(source)
		if mine then
			local label = mine.questName or mine.npcName or mine.zone
			if label then
				Add(format(L.EQUIVALENT_IS, label), 0.6, 0.85, 1)
			end
			if mine.questName and mine.npcName then
				Add(format(L.QUEST_GIVER, mine.npcName), 0.8, 0.8, 0.8)
			end
		end

		return true
	end

	-- A recipe, an achievement or a named instance all answer the question without
	-- needing coordinates.
	return RememberWaypoint(offer)
		or offer.recipeName ~= nil
		or offer.achievementID ~= nil
		or offer.instanceName ~= nil
end

local function AddOffers(source)
	local offers = ns.Offers(source.itemID, source.sourceID)
	if not offers then return false end

	local own = OwnFaction()

	-- Does this source have anything for our side at all?
	--
	-- This distinction is the whole point, and getting it wrong produced a panel
	-- that contradicted itself. One appearance sold by a Horde quartermaster AND
	-- an Alliance one is a single source with two vendors: the player already has
	-- their answer, and the other side is noise. A quest that exists once per
	-- faction is two separate sources, and there the warning is the useful part.
	--
	-- So: if anything here is ours, show only that and say nothing about the rest.
	-- Only when everything is for the other side does the warning earn its place.
	local hasOurs = false
	for _, offer in ipairs(offers) do
		if not OtherSide(offer, own) then
			hasOurs = true
			break
		end
	end

	local located = false
	local seen = {}

	for _, offer in ipairs(offers) do
		-- Their database can hold the same vendor twice, reached by two different
		-- paths through their tree, and both resolve to an identical line here.
		-- Keying on what the reader can actually see is what collapses them.
		local key = table.concat({
			tostring(offer.npcID or offer.questGiverID or offer.spellID
				or offer.achievementID or "?"),
			tostring(offer.mapID or "?"),
			tostring(offer.x or "?"),
			tostring(offer.y or "?"),
		}, ":")

		local other = OtherSide(offer, own)

		-- Dropped without a word when we already have our own vendor for this very
		-- source. Printing it, then warning about it, then pointing back at the
		-- vendor already on screen was three lines saying nothing.
		if not seen[key] and not (other and hasOurs) then
			seen[key] = true
			offer.otherFaction = other or nil
			if AddOffer(source, offer) then located = true end
		end
	end

	if waypoints.count and waypoints.count > 0 then
		local target = (own and waypoints[own]) or waypoints.any
			or waypoints.Alliance or waypoints.Horde

		-- The location is known. Whether it can be followed is a different matter.
		if type(TomTom) == "table" then
			-- Only worth warning about an arrow that exists. Saying "the arrow will
			-- only guide you once you get there" to someone with no arrow at all is
			-- a sentence about nothing.
			local far, continent = IsFarAway(target)
			if far then
				Add(continent and format(L.OTHER_CONTINENT_NAMED, continent)
					or L.OTHER_CONTINENT, 1, 0.6, 0.2)
			end

			Add(L.WAYPOINT_HINT_ONE)
		else
			Add(format(L.NEED_TOMTOM, Noun(source.sourceType)), 0.4, 0.8, 1)
		end
	end

	return located
end

local function AddGates(source)
	local req = source.requirements
	if req and req.factionName and req.factionStanding then
		Add(format(L.REQUIRES_REPUTATION, req.factionName, req.factionStanding), 1, 0.4, 0.4)
	end

	if source.holiday then
		Add(format(L.REQUIRES_HOLIDAY, source.holiday), 0.7, 0.9, 1)
	end

	-- useError is deliberately NOT printed. The client already shows that exact
	-- sentence at the top of its own tooltip, immediately above this panel, so
	-- repeating it made the reputation requirement appear three times on one
	-- screen: once from Blizzard, once from us, and once as this echo.
end

--------------------------------------------------------------------------------
-- Show and hide
--------------------------------------------------------------------------------

function ns.ShowFor(sourceID, anchorTo)
	local source = sourceID and ns.ClientSource(sourceID) or nil
	if not source then
		ns.HidePanel()
		return
	end

	ns.lastSource, ns.lastAnchor = sourceID, anchorTo

	ClearWaypoints()
	Reset()

	-- The appearance being looked at, so a waypoint left on the map an hour later
	-- still says what it was for.
	waypointSubject = source.name

	if source.sourceLabel then Add(source.sourceLabel, 0.7, 0.7, 0.7) end

	AddStatus(source)

	local located = AddDrops(source)

	-- Called even when the drop lines already answered "which boss", because the
	-- entrance coordinates live on the instance group and that is the thing a
	-- waypoint can actually point at. Skipping this was why a dungeon appearance
	-- offered no route at all.
	if AddOffers(source) then located = true end

	if not located then
		-- Three reasons for an empty panel, and they must not be conflated. The
		-- item is still being fetched, or nobody was asked because AllTheThings is
		-- absent, or it was asked and knew nothing. Only the last one is a gap in
		-- the data, and saying that when the truth is "wait half a second" blames
		-- the wrong party.
		if source.loading and not ns.HasATT() then
			-- Both true at once, so say the one the player can act on.
			Add(format(L.NEED_ATT, Noun(source.sourceType)), 1, 0.7, 0.3)
		elseif source.loading then
			Add(L.STILL_LOADING, 0.6, 0.6, 0.6)
		elseif not ns.HasATT() then
			Add(format(L.NEED_ATT, Noun(source.sourceType)), 1, 0.7, 0.3)
		else
			Add(L.SOURCE_NOT_RECORDED, 0.6, 0.6, 0.6)
		end
	end

	AddGates(source)

	-- Always offered, even when no location is known: the link is exactly what a
	-- player wants when the addon has nothing to say.
	Add(L.COPY_HINT_LINE)

	Finish(anchorTo)
end

--------------------------------------------------------------------------------
-- Redrawing when the client finally answers
--
-- Debounced, because GET_ITEM_INFO_RECEIVED arrives in bursts. A wardrobe page
-- full of uncached items would otherwise rebuild the panel dozens of times in a
-- few frames, and the last rebuild is the only one worth doing.
--------------------------------------------------------------------------------

local refreshQueued

function ns.RefreshPanel()
	if not panel or not panel:IsShown() then return end
	if refreshQueued then return end

	local function redraw()
		refreshQueued = nil
		if not panel or not panel:IsShown() then return end

		-- Ask the tile again first: the source choice itself may have been made
		-- with no item names available, and can now be made properly.
		if ns.ReResolveHovered and ns.ReResolveHovered() then return end
		if ns.lastSource and ns.lastAnchor then
			ns.ShowFor(ns.lastSource, ns.lastAnchor)
		end
	end

	if C_Timer and C_Timer.After then
		refreshQueued = true
		C_Timer.After(0.2, redraw)
	else
		redraw()
	end
end

function ns.HidePanel()
	ClearWaypoints()
	if panel then panel:Hide() end
end

ClearWaypoints()
