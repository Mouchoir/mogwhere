std = "lua51"

max_line_length = false
self = false

exclude_files = { ".release/", "dist/", "node_modules/" }

read_globals = {
	-- Lua and WoW additions
	"format", "wipe", "tinsert", "strsplit", "table", "string", "math", "select",
	"type", "tonumber", "tostring", "pairs", "ipairs", "next", "setmetatable",
	"rawget", "unpack", "floor", "pcall", "_G", "coroutine", "debugprofilestop",

	-- Client identity
	"GetBuildInfo", "GetLocale", "GetServerTime", "GetTime",

	-- Framework
	"CreateFrame", "C_Timer", "DEFAULT_CHAT_FRAME", "UIParent",

	-- Flavor detection
	"WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE", "WOW_PROJECT_CLASSIC",
	"WOW_PROJECT_BURNING_CRUSADE_CLASSIC", "WOW_PROJECT_WRATH_CLASSIC",
	"WOW_PROJECT_CATACLYSM_CLASSIC", "WOW_PROJECT_MISTS_CLASSIC",

	-- Addon loading
	"C_AddOns", "LoadAddOn", "IsAddOnLoaded", "GetAddOnInfo", "ReloadUI",

	-- Transmog collection
	"C_TransmogCollection", "C_Transmog", "Enum",

	-- Items
	"C_Item", "GetItemInfo", "GetItemInfoInstant",

	-- Instances and difficulties
	"EJ_GetInstanceInfo", "EJ_GetEncounterInfo", "GetDifficultyInfo",

	-- Reputation
	"GetFactionInfoByID", "C_Reputation",

	-- Achievements
	"GetAchievementInfo", "GetAchievementNumCriteria", "GetAchievementCriteriaInfo",

	-- Nameplates
	"C_NamePlate", "UnitIsUnit", "C_CVar", "GetCVar", "GetBindingKey",

	-- Merchant harvesting
	"GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink",
	"GetMerchantItemCostInfo", "GetMerchantItemCostItem", "GetMerchantItemMaxStack",

	-- Units and location
	"UnitName", "UnitGUID", "UnitExists", "C_Map",

	-- Wardrobe UI
	"WardrobeCollectionFrame", "WardrobeFrame", "CollectionsJournal",
	"CollectionWardrobeUtil", "hooksecurefunc",

	-- Source type labels
	"TRANSMOG_SOURCE_1", "TRANSMOG_SOURCE_2", "TRANSMOG_SOURCE_3",
	"TRANSMOG_SOURCE_4", "TRANSMOG_SOURCE_5", "TRANSMOG_SOURCE_6",

	-- Names and money formatting
	"C_CurrencyInfo", "GetCoinTextureString", "C_Spell", "GetSpellInfo",

	-- Input state
	"IsShiftKeyDown", "IsControlKeyDown", "IsAltKeyDown",

	-- Faction and quests
	"UnitFactionGroup", "FACTION_HORDE", "FACTION_ALLIANCE", "C_QuestLog",

	-- Optional third party
	"TomTom",
}

globals = {
	"MogWhereDB",
	"SLASH_MOGWHERE1",
	"SLASH_MOGWHERE2",
	"SlashCmdList",
	"MogWhereTooltipScanner",
}
