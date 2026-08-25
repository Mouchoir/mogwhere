local _, ns = ...

--------------------------------------------------------------------------------
-- Layer 3: harvest the live client
--
-- This is the layer that makes the addon worth writing. Every time a merchant
-- window opens, the whole inventory is readable: the items, the gold price, the
-- currency or item costs, the vendor's own name and the coordinates of the spot
-- the player is standing on. That is vendor, cost and location, taken from the
-- live 5.5.4 servers, with no shipped database and nothing to go stale.
--
-- It is also the only layer that can know about content added by Mists Classic
-- itself. A Mists era dataset has never heard of the August Celestials exchange,
-- because it did not exist in 5.4.8.
--
-- The NPC name comes from UnitName("npc") while the window is open. It is worth
-- saying why out loud: the usual trick of resolving a name from a creature id by
-- feeding a fabricated "unit:Creature-0-0-0-0-<id>-0" hyperlink into a tooltip
-- makes this client print "Unknown unit" on screen, over and over. That is the
-- error spam AllTheThings produces on Mists. Reading the unit we are talking to
-- costs nothing and cannot misfire.
--------------------------------------------------------------------------------

local Fn = ns.Fn
local Try = ns.Try

-- Creature-0-<server>-<instance>-<zoneUID>-<creatureID>-<spawnUID>
local function CreatureID(guid)
	if type(guid) ~= "string" then return nil end

	local field, index = nil, 0
	for part in guid:gmatch("[^-]+") do
		index = index + 1
		if index == 6 then
			field = part
			break
		end
	end

	return tonumber(field)
end

local function Position()
	local map = C_Map
	local best = Fn(map and map.GetBestMapForUnit)
	local at = Fn(map and map.GetPlayerMapPosition)
	if not best or not at then return nil end

	local mapID = Try(best, "player")
	if not mapID then return nil end

	local point = Try(at, mapID, "player")
	if not point then return mapID end

	-- The position object exposes GetXY on this engine.
	local x, y = Try(point.GetXY, point)
	if not x then return mapID end

	-- Stored as percentages, which is what a waypoint wants.
	return mapID, x * 100, y * 100
end

-- Extended costs: currencies and items the vendor asks for on top of, or instead
-- of, gold.
local function ExtendedCosts(index)
	local count = Try(Fn(GetMerchantItemCostInfo), index)
	if type(count) ~= "number" or count == 0 then return nil end

	local get = Fn(GetMerchantItemCostItem)
	if not get then return nil end

	local out = {}
	for slot = 1, count do
		local _, value, link, currencyName = Try(get, index, slot)
		if value and value > 0 then
			local entry = { quantity = value }

			-- A link means an item is being asked for, a bare name means a
			-- currency, which is how the merchant frame itself tells them apart.
			if link then
				entry.kind = "item"
				entry.itemID = Try(Fn(GetItemInfoInstant), link)
			else
				entry.kind = "currency"
				entry.currencyName = currencyName
			end

			out[#out + 1] = entry
		end
	end

	return #out > 0 and out or nil
end

--------------------------------------------------------------------------------
-- The scan itself
--------------------------------------------------------------------------------

function ns.HarvestMerchant()
	local db = ns.db
	if not db then return nil end

	local numItems = Try(Fn(GetMerchantNumItems))
	if type(numItems) ~= "number" or numItems == 0 then return nil end

	local npcName = UnitExists and UnitExists("npc") and UnitName("npc") or nil
	local npcID = CreatureID(UnitGUID and UnitGUID("npc"))

	-- Without an id there is nothing stable to key the vendor on, so the scan is
	-- dropped rather than filed under a name that two servers may disagree on.
	if not npcID then return nil end

	local mapID, x, y = Position()

	db.vendors = db.vendors or {}
	local vendor = db.vendors[npcID] or {}
	vendor.name = npcName or vendor.name
	vendor.mapID = mapID or vendor.mapID
	vendor.x = x or vendor.x
	vendor.y = y or vendor.y
	vendor.asOf = GetServerTime and GetServerTime() or nil
	vendor.items = vendor.items or {}

	local recorded = 0
	for index = 1, numItems do
		local link = Try(Fn(GetMerchantItemLink), index)
		local itemID = link and Try(Fn(GetItemInfoInstant), link) or nil

		if itemID then
			local _, _, price, stack = Try(Fn(GetMerchantItemInfo), index)
			vendor.items[itemID] = {
				copper = (price and price > 0) and price or nil,
				stack = (stack and stack > 1) and stack or nil,
				costs = ExtendedCosts(index),
			}
			recorded = recorded + 1
		end
	end

	db.vendors[npcID] = vendor
	return recorded, npcName or tostring(npcID)
end

-- Offers for one item, in the same shape the ATT bridge answers, so the display
-- path does not care which layer produced the line.
function ns.HarvestedOffers(itemID)
	local db = ns.db
	if not db or not db.vendors or type(itemID) ~= "number" then return nil end

	local out = {}
	for npcID, vendor in pairs(db.vendors) do
		local offer = vendor.items and vendor.items[itemID]
		if offer then
			local costs
			if offer.copper then costs = { { kind = "gold", amount = offer.copper } } end
			if offer.costs then
				costs = costs or {}
				for _, cost in ipairs(offer.costs) do costs[#costs + 1] = cost end
			end

			out[#out + 1] = {
				source = "harvest",
				npcID = npcID,
				npcName = vendor.name,
				costs = costs,
				zone = ns.ZoneName(vendor.mapID),
				mapID = vendor.mapID,
				x = vendor.x,
				y = vendor.y,
				asOf = vendor.asOf,
			}
		end
	end

	return #out > 0 and out or nil
end

-- Harvested data wins over ATT: it came from this client, on this build, today.
function ns.Offers(itemID, sourceID)
	return ns.HarvestedOffers(itemID) or ns.ATTOffers(itemID, sourceID)
end
