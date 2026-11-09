local _, ns = ...

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
}

-- How a path sample was traveled. Stored on the point, not as a string.
ns.Travel = {
	FOOT = 0,
	MOUNT = 1,
	FLIGHT = 2,
	GHOST = 3,
}

ns.KindName = {
	[1] = "Kill",
	[2] = "Quest accepted",
	[3] = "Quest turned in",
	[4] = "Death",
	[5] = "Summon",
	[6] = "Hearth",
	[7] = "Flight start",
	[8] = "Flight end",
	[9] = "Mounted",
	[10] = "Dismounted",
	[11] = "AFK start",
	[12] = "AFK end",
	[13] = "Entered instance",
	[14] = "Left instance",
	[15] = "Zone",
	[16] = "Level up",
	[17] = "Joined",
	[18] = "Portal",
	[19] = "Trainer",
	[20] = "Campfire",
	[21] = "Sleeping bag",
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
	[1] = "Alchemy",
	[2] = "Blacksmithing",
	[3] = "Enchanting",
	[4] = "Engineering",
	[5] = "Herbalism",
	[6] = "Inscription",
	[7] = "Jewelcrafting",
	[8] = "Leatherworking",
	[9] = "Mining",
	[10] = "Skinning",
	[11] = "Tailoring",
	[12] = "Cooking",
	[13] = "First Aid",
	[14] = "Fishing",
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

-- Campfire and sleeping-bag auras. A confirmed result has already earned the rest.
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
	[1] = "Dungeon",
	[2] = "Raid",
	[3] = "PvP",
	[4] = "Arena",
	[5] = "Scenario",
	[6] = "Instance",
}

ns.CONTINUE_SECONDS = 180
ns.SAMPLE_CAP = 20000
ns.COORD_SCALE = 10000
