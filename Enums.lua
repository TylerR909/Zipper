local _, ns = ...

if not ns.L then
	ns.L = setmetatable({}, { __index = function(_, key) return key end })
end
local L = ns.L

-- Stored as numbers. Names and colors are for code and the replay, not the saved data.
ns.Kind = {
	KILL = 1,
	QUEST_ACCEPT = 2,
	QUEST_TURNIN = 3,
	DEATH = 4,
	SUMMON = 5,
	HEARTH = 6,
	FLIGHT_START = 7,
	FLIGHT_END = 8,
	MOUNT = 9,
	DISMOUNT = 10,
	AFK_START = 11,
	AFK_END = 12,
	INSTANCE_ENTER = 13,
	INSTANCE_LEAVE = 14,
	ZONE = 15,
	LEVEL = 16,
	GROUP = 17,
	PORTAL = 18,
	TRAINER = 19,
	CAMP = 20,
	SLEEP = 21,
	EAT = 22,
	BOSS = 23,
}

-- How a path sample was traveled. Stored on the point, not as a string.
ns.Travel = {
	FOOT = 0,
	MOUNT = 1,
	FLIGHT = 2,
	GHOST = 3,
}

ns.KindName = {
	[1] = L["Kill"],
	[2] = L["Quest accepted"],
	[3] = L["Quest turned in"],
	[4] = L["Death"],
	[5] = L["Summon"],
	[6] = L["Hearth"],
	[7] = L["Flight start"],
	[8] = L["Flight end"],
	[9] = L["Mounted"],
	[10] = L["Dismounted"],
	[11] = L["AFK start"],
	[12] = L["AFK end"],
	[13] = L["Entered instance"],
	[14] = L["Left instance"],
	[15] = L["Zone"],
	[16] = L["Level up"],
	[17] = L["Joined"],
	[18] = L["Portal"],
	[19] = L["Trainer"],
	[20] = L["Campfire"],
	[21] = L["Sleeping bag"],
	[22] = L["Eating"],
	[23] = L["Boss"],
}

ns.KindColor = {
	[1] = { 1.00, 0.25, 0.20 },
	[2] = { 1.00, 0.85, 0.20 },
	[3] = { 0.30, 1.00, 0.40 },
	[4] = { 0.75, 0.75, 0.75 },
	[5] = { 0.75, 0.40, 1.00 },
	[6] = { 0.35, 0.60, 1.00 },
	[7] = { 0.20, 0.90, 0.90 },
	[8] = { 0.10, 0.55, 0.60 },
	[9] = { 1.00, 0.55, 0.15 },
	[10] = { 0.60, 0.35, 0.15 },
	[11] = { 0.55, 0.55, 0.85 },
	[12] = { 0.35, 0.35, 0.55 },
	[13] = { 1.00, 0.40, 0.70 },
	[14] = { 0.60, 0.25, 0.45 },
	[15] = { 0.92, 0.92, 0.92 },
	[16] = { 1.00, 0.95, 0.55 },
	[17] = { 0.45, 0.75, 1.00 },
	[18] = { 0.20, 0.78, 0.95 },
	[19] = { 0.78, 0.58, 0.28 },
	[20] = { 0.95, 0.45, 0.12 },
	[21] = { 0.55, 0.62, 0.95 },
	[22] = { 0.72, 0.58, 0.32 },
	[23] = { 1.00, 0.55, 0.20 },
}

-- Class file from UnitClass. Stored once per person, not on every path event.
ns.ClassName = {
	WARRIOR = "Warrior",
	PALADIN = "Paladin",
	HUNTER = "Hunter",
	ROGUE = "Rogue",
	PRIEST = "Priest",
	DEATHKNIGHT = "Death Knight",
	SHAMAN = "Shaman",
	MAGE = "Mage",
	WARLOCK = "Warlock",
	MONK = "Monk",
	DRUID = "Druid",
	DEMONHUNTER = "Demon Hunter",
	EVOKER = "Evoker",
}

-- Mage travel spells, matched on the cast name so a new city does not need a new id.
function ns.TravelCast(name)
	if type(name) ~= "string" then
		return nil
	end
	if name == "Ritual of Summoning" then
		return "ritual"
	end
	if string.sub(name, 1, 9) == "Teleport:" or string.sub(name, 1, 7) == "Portal:" then
		return "portal"
	end
	return nil
end

-- Profession trainers. The number is stored. The name is only for the tooltip.
ns.ProfessionName = {
	[1] = L["Alchemy"],
	[2] = L["Blacksmithing"],
	[3] = L["Enchanting"],
	[4] = L["Engineering"],
	[5] = L["Herbalism"],
	[6] = L["Inscription"],
	[7] = L["Jewelcrafting"],
	[8] = L["Leatherworking"],
	[9] = L["Mining"],
	[10] = L["Skinning"],
	[11] = L["Tailoring"],
	[12] = L["Cooking"],
	[13] = L["First Aid"],
	[14] = L["Fishing"],
}

local PROFESSION_WORD = {
	alchemy = 1,
	blacksmith = 2,
	enchant = 3,
	engineer = 4,
	herbal = 5,
	inscript = 6,
	jewel = 7,
	leather = 8,
	mining = 9,
	skinning = 10,
	tailor = 11,
	cooking = 12,
	["first aid"] = 13,
	fishing = 14,
}

-- Campfire and sleeping-bag auras.
-- ready=false is proximity (at the fire). ready=true only confirms earned rest and
-- can linger after you leave, so ReadRest must not treat it as still camping.
function ns.RestSignal(name, spellID)
	if spellID == 1283391 then
		return "camp", false
	end
	if type(name) ~= "string" then
		return nil
	end
	if name == "Camp Benefits" or name == "Boosted Rest" then
		return "camp", true
	end
	if name == "Welcoming Campfire" or name == "Campfire Nearby" then
		return "camp", false
	end
	if name == "Well-Rested" then
		return "sleep", true
	end
	return nil
end

-- Food and Drink while seated. Well Fed lasts after the meal and must not match.
function ns.MealSignal(name)
	if type(name) ~= "string" then
		return false
	end
	return name == "Food" or name == "Drink" or name == "Refreshment"
end

function ns.ProfessionId(line)
	if type(line) ~= "string" or line == "" then
		return 0
	end
	local lower = string.lower(line)
	for word, id in pairs(PROFESSION_WORD) do
		if string.find(lower, word, 1, true) then
			return id
		end
	end
	return 0
end

ns.Instance = {
	PARTY = 1,
	RAID = 2,
	PVP = 3,
	ARENA = 4,
	SCENARIO = 5,
	OTHER = 6,
}

ns.InstanceName = {
	[1] = L["Dungeon"],
	[2] = L["Raid"],
	[3] = L["PvP"],
	[4] = L["Arena"],
	[5] = L["Scenario"],
	[6] = L["Instance"],
}

function ns.ClassLabel(classFile)
	local names = LOCALIZED_CLASS_NAMES_MALE or LOCALIZED_CLASS_NAMES_FEMALE
	if classFile and type(names) == "table" and names[classFile] then
		return names[classFile]
	end
	return ns.ClassName and ns.ClassName[classFile]
end

ns.CONTINUE_SECONDS = 180
-- A finished stop closer than this to its first spot, with nothing else done, is quiet.
ns.QUIET_YARDS = 250
ns.SAMPLE_CAP = 20000
ns.COORD_SCALE = 10000
