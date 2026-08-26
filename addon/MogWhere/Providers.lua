local _, ns = ...

--------------------------------------------------------------------------------
-- Layer 2: AllTheThings, if the player happens to have it
--
-- ATT carries exactly the three things the client withholds: which NPC sells an
-- item, what it costs and where that NPC stands. For Mists its database holds
-- roughly 49 000 appearance sources, 10 500 cost blocks and 20 700 coordinate
-- blocks, which is years of community curation.
--
-- Which is precisely why this is a read at runtime and not a copy. Their package
-- ships two contradictory licence files, MIT in LICENSE and "All Rights Reserved"
-- in LICENSE.txt, so redistributing their data would be reckless on top of being
-- rude. Reading a global that they deliberately export is neither.
--
-- The shape of their groups was read off their database files, so the parent walk
-- below is an informed guess until it has been confirmed against a live client.
-- Everything goes through Try for that reason: a wrong assumption degrades to
-- "no vendor known" instead of an error.
--------------------------------------------------------------------------------

local Try = ns.Try

-- src/base.lua exports the addon table under both names.
local function App()
	local app = _G.ATTC or _G.AllTheThings
	if type(app) ~= "table" then return nil end
	if type(app.SearchForField) ~= "function" then return nil end
	return app
end

function ns.HasATT()
	return App() ~= nil
end

local MAX_PARENT_WALK = 6

-- How far above the item an npc id is still believable.
--
-- This is the fix for a real wrong answer: a tabard from a quest started by Uther
-- was reported as "sold by the Lich King". The walk had climbed six levels, hit a
-- category header carrying an npcID, and taken it. An ancestor that far up
-- describes a region of their tree, not the thing handing you the item.
--
-- A vendor group is the direct parent of the item it sells, so one level is the
-- normal case and two is generous. Beyond that, an id is somebody else's.
local MAX_NPC_DEPTH = 2

-- A header further up than this is a category of their database, not a fact about
-- the item.
local MAX_HEADER_DEPTH = 3

-- Fields are collected with the depth they were found at, so each one can be
-- trusted or rejected on its own rather than as a lump.
local function Ancestry(group)
	local found = {}
	local node, depth = group, 0

	local function take(key, value)
		if value ~= nil and found[key] == nil then
			found[key] = value
			found[key .. "Depth"] = depth
		end
	end

	while type(node) == "table" and depth < MAX_PARENT_WALK do
		take("npcID", node.npcID or node.creatureID)
		take("questID", node.questID)
		-- Their quest giver list, which sits on the quest itself and is therefore
		-- the only trustworthy source of a giver.
		take("givers", node.qgs)
		take("achievementID", node.achievementID)
		take("spellID", node.spellID or node.recipeID)
		take("learnedAt", node.learnedAt)
		take("creatures", node.crs)
		take("coords", node.coords)
		-- Where their tree puts this item, which is information the client cannot
		-- always supply on its own. GetAppearanceSourceDrops only knows what the
		-- Encounter Journal knows, so anything reached through shared loot or a
		-- container comes back with no instance and no boss at all. The place in
		-- their hierarchy is the answer in those cases.
		-- The instance id AND that same node's own map, taken together on purpose.
		--
		-- EJ_GetInstanceInfo answered nil for Karazhan's id 745 with the journal
		-- loaded, because this client's Encounter Journal simply does not carry a
		-- Burning Crusade raid. The journal is a dead end for anything older than
		-- the expansion the client ships. An instance map, on the other hand, is
		-- named by C_Map like any other, on every build.
		if node.instanceID and found.instanceID == nil then
			take("instanceID", node.instanceID)
			found.instanceMapID = node.mapID
		end
		take("difficultyID", node.difficultyID)
		take("encounterID", node.encounterID)
		-- Headers carry a negative id. Reading their name is safe precisely because
		-- it is negative: their metatable only reaches for the fabricated unit
		-- hyperlink when the id is positive.
		if node.headerID and node.headerID < 0 then take("headerID", node.headerID) end
		if node.npcID and node.npcID < 0 then take("headerID", node.npcID) end
		if node.encounterID == nil and node.creatureID and node.creatureID < 0 then
			take("headerID", node.creatureID)
		end
		take("minReputation", node.minReputation)
		take("maxReputation", node.maxReputation)
		if found.faction == nil then take("faction", node.r) end

		if found.npcID == nil and type(node.providers) == "table" then
			for _, provider in ipairs(node.providers) do
				if type(provider) == "table" and provider[1] == "n" then
					take("npcID", provider[2])
					break
				end
			end
		end

		node = node.parent
		depth = depth + 1
	end

	-- An npc id found too far up is discarded rather than presented as fact.
	if found.npcID and (found.npcIDDepth or 0) > MAX_NPC_DEPTH then
		found.npcID = nil
	end

	-- Same reasoning for headers, and the depth is what separates a useful one from
	-- noise. "Common Boss Drop" sits right above the item and says something real.
	-- "Dungeons & Raids" is the root of their whole tree and says nothing at all.
	-- Both are headers; only their distance tells them apart.
	if found.headerID and (found.headerIDDepth or 0) > MAX_HEADER_DEPTH then
		found.headerID = nil
	end

	if MogWhereDB and MogWhereDB.config and MogWhereDB.config.debug then
		MogWhereDB.diag = MogWhereDB.diag or {}
		MogWhereDB.diag.anc_instanceID = found.instanceID or "nil"
		MogWhereDB.diag.anc_instanceDepth = found.instanceIDDepth or "nil"
		MogWhereDB.diag.anc_headerID = found.headerID or "nil"
		MogWhereDB.diag.anc_walked = depth
	end

	return found
end

--------------------------------------------------------------------------------
-- Faction
--
-- Their r field carries an Enum.FlightPathFaction value, the same comparison
-- their own Transmog.lua makes against app.FactionID. The label comes from the
-- client globals FACTION_HORDE and FACTION_ALLIANCE so it is already translated
-- in every locale, and never from a string of ours.
--------------------------------------------------------------------------------

function ns.FactionTag(r)
	if r == nil then return nil end

	local horde = Enum and Enum.FlightPathFaction and Enum.FlightPathFaction.Horde
	if horde ~= nil and r == horde then return "Horde", FACTION_HORDE end

	local alliance = Enum and Enum.FlightPathFaction and Enum.FlightPathFaction.Alliance
	if alliance ~= nil and r == alliance then return "Alliance", FACTION_ALLIANCE end

	return nil
end

--------------------------------------------------------------------------------
-- Safe naming
--
-- There is no way to turn a creature id into a name on this client that does not
-- go through the broken hyperlink trick. So we do not try. A vendor is named only
-- when we have met it ourselves, and the actionable part of the answer is the
-- zone and the coordinates, which need no name at all.
--------------------------------------------------------------------------------

function ns.ZoneName(mapID)
	if type(mapID) ~= "number" then return nil end
	local info = Try(ns.Fn(C_Map and C_Map.GetMapInfo), mapID)
	return type(info) == "table" and info.name or nil
end

-- Recipe names come from the spell, which the client resolves cleanly, with none
-- of the trickery an npc name would need.
function ns.RecipeName(spellID)
	if type(spellID) ~= "number" then return nil end

	local info = Try(ns.Fn(C_Spell and C_Spell.GetSpellInfo), spellID)
	if type(info) == "table" and info.name then return info.name end

	local name = Try(ns.Fn(GetSpellInfo), spellID)
	if type(name) == "string" and name ~= "" then return name end

	return nil
end

-- Negative ids only. Their metatable answers these from a plain table of header
-- names, without the tooltip trick that positive ids trigger, so this is a normal
-- lookup rather than something to be careful with.
function ns.HeaderName(headerID)
	if type(headerID) ~= "number" or headerID >= 0 then return nil end

	local app = App()
	local cache = app and app.NPCNameFromID
	if type(cache) ~= "table" then return nil end

	local name = Try(function() return cache[headerID] end)
	if type(name) == "string" and name ~= "" then return name end
	return nil
end

function ns.ATTNPCName(npcID)
	if type(npcID) ~= "number" then return nil end

	local app = App()
	local cache = app and app.NPCNameFromID
	if type(cache) ~= "table" then return nil end

	local name = rawget(cache, npcID)
	if type(name) == "string" and name ~= "" then return name end
	return nil
end

-- cost blocks look like { {"i", itemID, quantity}, {"c", currencyID, quantity} }
-- and a bare number means copper.
local function Costs(raw)
	if type(raw) == "number" then return { { kind = "gold", amount = raw } } end
	if type(raw) ~= "table" then return nil end

	local out = {}
	for _, entry in ipairs(raw) do
		if type(entry) == "table" then
			local kind, id, quantity = entry[1], entry[2], entry[3]
			if kind == "i" then
				out[#out + 1] = { kind = "item", itemID = id, quantity = quantity or 1 }
			elseif kind == "c" then
				out[#out + 1] = { kind = "currency", currencyID = id, quantity = quantity or 1 }
			elseif kind == "g" then
				out[#out + 1] = { kind = "gold", amount = id }
			end
		end
	end

	return #out > 0 and out or nil
end

-- coords are keyed by mapID and hold pairs, sometimes a third element repeating
-- the map. Only the first point is kept: a waypoint wants one destination.
local function FirstCoord(coords)
	if type(coords) ~= "table" then return nil end

	for mapID, points in pairs(coords) do
		if type(points) == "table" then
			local first = points[1]
			if type(first) == "table" and first[1] and first[2] then
				return tonumber(first[3]) or tonumber(mapID), first[1], first[2]
			end
		end
	end

	return nil
end

--------------------------------------------------------------------------------
-- Finding the group
--
-- Three lookups, in decreasing precision, because their cache is subtler than it
-- looks and the obvious call is the wrong one:
--
-- 1. sourceID. Their Cache.lua indexes it, and the client hands us the sourceID
--    for free, so this is the exact join with no ambiguity at all.
-- 2. SearchForObject on itemID. Items are cached under both the base itemID and a
--    composite modItemID, and this is the only entry point that falls back
--    between the two. A vendor item carrying a modifier, which is common, is
--    invisible to the raw lookup.
-- 3. The raw SearchForField, as a last resort.
--------------------------------------------------------------------------------

local function Groups(app, itemID, sourceID)
	if type(sourceID) == "number" then
		local hits = Try(app.SearchForField, "sourceID", sourceID)
		if type(hits) == "table" and #hits > 0 then return hits end
	end

	if type(itemID) ~= "number" then return nil end

	if type(app.SearchForObject) == "function" then
		local hits = Try(app.SearchForObject, "itemID", itemID, nil, true)
		if type(hits) == "table" and #hits > 0 then return hits end
	end

	local hits = Try(app.SearchForField, "itemID", itemID)
	if type(hits) == "table" and #hits > 0 then return hits end

	return nil
end

-- Returns a list of offers, or nil when ATT knows nothing about this appearance.
function ns.ATTOffers(itemID, sourceID)
	local app = App()
	if not app then return nil end

	local hits = Groups(app, itemID, sourceID)
	if type(hits) ~= "table" then return nil end

	local out = {}
	for _, group in ipairs(hits) do
		if type(group) == "table" then
			local at = Ancestry(group)
			local costs = Costs(group.cost)
			local mapID, x, y = FirstCoord(at.coords or group.coords)
			local side, sideName = ns.FactionTag(at.faction)

			-- A quest giver is a qgs entry, never an npcID inherited from an
			-- ancestor. Keeping the two apart is what stops a quest tabard from
			-- being reported as sold by a raid boss.
			local giver = type(at.givers) == "table" and at.givers[1] or nil

			if at.npcID or costs or mapID or at.spellID or at.achievementID or giver then
				out[#out + 1] = {
					source = "att",
					npcID = at.npcID,
					questGiverID = giver,
					npcName = ns.NPCName(at.npcID),
					questGiverName = ns.NPCName(giver),
					zone = ns.ZoneName(mapID),
					costs = costs,
					mapID = mapID,
					x = x,
					y = y,
					questID = at.questID,
					questName = ns.QuestTitle(at.questID),
					spellID = at.spellID,
					recipeName = ns.RecipeName(at.spellID),
					learnedAt = at.learnedAt,
					-- Exposed on every offer, not just recipes. A rare that drops
					-- the appearance itself is something the player has to find and
					-- kill exactly like a recipe drop, and hiding the id behind a
					-- recipe-shaped field meant the star could never mark it.
					creatures = at.creatures,
					recipeDroppedBy = at.creatures,
					achievementID = at.achievementID,
					instanceName = ns.InstanceName(at.instanceID, at.instanceMapID),
					difficultyName = ns.DifficultyName(at.difficultyID),
					encounterName = ns.EncounterName(at.encounterID),
					headerName = ns.HeaderName(at.headerID),
					minReputation = at.minReputation,
					maxReputation = at.maxReputation,
					faction = side,
					factionName = sideName,
				}
			end
		end
	end

	return #out > 0 and out or nil
end
