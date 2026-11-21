local _, ns = ...

if not ns.L then
	ns.L = setmetatable({}, { __index = function(_, key) return key end })
end
local L = ns.L

-- Stored as numbers. Names and colors are for code and the replay, not the saved data.
-- Append-only: these numbers are packed into Z3 SavedVariables and must never be renumbered.
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
	FISH = 24,
	IDLE = 25,
	CRAFT = 26,
}

-- How a path sample was traveled. Stored on the point, not as a string.
ns.Travel = {
	FOOT = 0,
	MOUNT = 1,
	FLIGHT = 2,
	GHOST = 3,
}

-- Single declarative definition for every event kind.
-- Config, DB, Replay, and Viz read from ns.EventSpec rather than keeping parallel lists:
--   name:             Localized display name (populates ns.KindName)
--   color:            { r, g, b } default color (populates ns.KindColor)
--   shape:            "point" | "span" (extra 0=start, 1=end) | "pair" | "pairEnd"
--   pairEnd / pairStart: linked kind id for "pair" / "pairEnd" events
--   config:           { key, page = "road"|"moments", label, order } creates a Settings toggle
--   configKey:        shares an existing Settings toggle without creating a second checkbox
--   keepsSession:     true when this event prevents a stop from being dropped as quiet
--   qualifiesCompany: true when this event credits active party spans as shared moments
--   pip:              false (off the map) or { shape="circle"|"ring", size, color?, milestone?, legend? }
--   playhead:         "fish" | "busy" (suppresses parked ring) | "parked" | nil
--   blocksAFK:        true when an active span of this kind suppresses AFK
--   blocksIdle:       true when an active span of this kind counts as busy for Idle
--   pause:            { key, label, order, still?, custom? } feeds Viz pauses + Pauses chart
local Kind = ns.Kind
ns.EventSpec = {}
ns.KindName = {}
ns.KindColor = {}

local function DefineEvent(kind, spec)
	spec.kind = kind
	spec.shape = spec.shape or "point"
	ns.EventSpec[kind] = spec
	ns.KindName[kind] = spec.name
	ns.KindColor[kind] = spec.color
end

DefineEvent(Kind.KILL, {
	name = L["Kill"],
	color = { 1.00, 0.25, 0.20 },
	config = { key = "kills", page = "moments", label = L["Kills"], order = 1 },
	keepsSession = true,
	qualifiesCompany = true,
	pip = {
		shape = "circle",
		size = 5,
		color = { 0.86, 0.12, 0.10 },
		legend = { order = 1, size = 8 },
	},
})

DefineEvent(Kind.QUEST_ACCEPT, {
	name = L["Quest accepted"],
	color = { 1.00, 0.85, 0.20 },
	config = { key = "questAccept", page = "moments", label = L["Quest pickup"], order = 2 },
	keepsSession = true,
	qualifiesCompany = true,
	-- Quest pips stay darker than KindColor so dense clusters still read on the map.
	pip = {
		shape = "circle",
		size = 6,
		color = { 0.58, 0.44, 0.06 },
		legend = { order = 2, label = L["Quest pickup"], size = 8 },
	},
})

DefineEvent(Kind.QUEST_TURNIN, {
	name = L["Quest turned in"],
	color = { 0.30, 1.00, 0.40 },
	config = { key = "questTurnin", page = "moments", label = L["Quest turn-in"], order = 3 },
	keepsSession = true,
	qualifiesCompany = true,
	pip = {
		shape = "circle",
		size = 6,
		color = { 0.235, 0.702, 0.443 },
		legend = { order = 3, label = L["Quest turn-in"], size = 8 },
	},
})

DefineEvent(Kind.DEATH, {
	name = L["Death"],
	color = { 0.75, 0.75, 0.75 },
	config = { key = "death", page = "moments", label = L["Deaths"], order = 4 },
	keepsSession = true,
	qualifiesCompany = true,
	pip = {
		shape = "ring",
		size = 8,
		color = { 0.72, 0.08, 0.08 },
		milestone = true,
		legend = { order = 4, size = 10 },
	},
})

DefineEvent(Kind.SUMMON, {
	name = L["Summon"],
	color = { 0.75, 0.40, 1.00 },
	config = { key = "summon", page = "moments", label = L["Summons"], order = 6 },
	keepsSession = true,
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.HEARTH, {
	name = L["Hearth"],
	color = { 0.35, 0.60, 1.00 },
	config = { key = "hearth", page = "moments", label = L["Hearths"], order = 5 },
	keepsSession = true,
	pip = { shape = "circle", size = 7, legend = { order = 8, size = 9 } },
})

DefineEvent(Kind.FLIGHT_START, {
	name = L["Flight start"],
	color = { 0.20, 0.90, 0.90 },
	shape = "pair",
	pairEnd = Kind.FLIGHT_END,
	config = { key = "flight", page = "road", label = L["Flights"], order = 3 },
	keepsSession = true,
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.FLIGHT_END, {
	name = L["Flight end"],
	color = { 0.10, 0.55, 0.60 },
	shape = "pairEnd",
	pairStart = Kind.FLIGHT_START,
	configKey = "flight",
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.MOUNT, {
	name = L["Mounted"],
	color = { 1.00, 0.55, 0.15 },
	shape = "pair",
	pairEnd = Kind.DISMOUNT,
	config = { key = "mount", page = "road", label = L["Mount and dismount"], order = 2 },
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.DISMOUNT, {
	name = L["Dismounted"],
	color = { 0.60, 0.35, 0.15 },
	shape = "pairEnd",
	pairStart = Kind.MOUNT,
	configKey = "mount",
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.AFK_START, {
	name = L["AFK start"],
	color = { 0.55, 0.55, 0.85 },
	shape = "pair",
	pairEnd = Kind.AFK_END,
	config = { key = "afk", page = "road", label = L["AFK"], order = 5 },
	pip = { shape = "circle", size = 7 },
	playhead = "parked",
	pause = { key = "afk", label = L["AFK"], order = 2, still = false },
})

DefineEvent(Kind.AFK_END, {
	name = L["AFK end"],
	color = { 0.35, 0.35, 0.55 },
	shape = "pairEnd",
	pairStart = Kind.AFK_START,
	configKey = "afk",
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.INSTANCE_ENTER, {
	name = L["Entered instance"],
	color = { 1.00, 0.40, 0.70 },
	shape = "pair",
	pairEnd = Kind.INSTANCE_LEAVE,
	config = { key = "instance", page = "moments", label = L["Dungeons and raids"], order = 9 },
	keepsSession = true,
	qualifiesCompany = true,
	pip = { shape = "circle", size = 7, legend = { order = 13, size = 9 } },
})

DefineEvent(Kind.INSTANCE_LEAVE, {
	name = L["Left instance"],
	color = { 0.60, 0.25, 0.45 },
	shape = "pairEnd",
	pairStart = Kind.INSTANCE_ENTER,
	configKey = "instance",
	pip = { shape = "circle", size = 7 },
})

DefineEvent(Kind.ZONE, {
	name = L["Zone"],
	color = { 0.92, 0.92, 0.92 },
	config = { key = "zone", page = "road", label = L["Zone changes"], order = 4 },
	pip = false,
})

DefineEvent(Kind.LEVEL, {
	name = L["Level up"],
	color = { 1.00, 0.95, 0.55 },
	keepsSession = true,
	pip = {
		shape = "ring",
		size = 9,
		color = { 1.00, 0.92, 0.45 },
		milestone = true,
		legend = { order = 5, size = 10 },
	},
})

DefineEvent(Kind.GROUP, {
	name = L["Joined Party"],
	color = { 0.45, 0.75, 1.00 },
	config = { key = "party", page = "moments", label = L["Party members"], order = 10 },
	pip = { shape = "circle", size = 7, legend = { order = 7, size = 9 } },
})

DefineEvent(Kind.PORTAL, {
	name = L["Teleport"],
	color = { 0.20, 0.78, 0.95 },
	config = { key = "portal", page = "moments", label = L["Teleports and portals"], order = 7 },
	keepsSession = true,
	pip = { shape = "circle", size = 7, legend = { order = 9, size = 9 } },
})

DefineEvent(Kind.TRAINER, {
	name = L["Trainer"],
	color = { 0.78, 0.58, 0.28 },
	config = { key = "trainer", page = "moments", label = L["Trainers"], order = 8 },
	keepsSession = true,
	pip = { shape = "circle", size = 7, legend = { order = 12, size = 9 } },
})

DefineEvent(Kind.CAMP, {
	name = L["Campfire"],
	color = { 0.95, 0.45, 0.12 },
	shape = "span",
	config = { key = "rest", page = "road", label = L["Camps and sleeping bags"], order = 7 },
	keepsSession = true,
	pip = { shape = "circle", size = 7, legend = { order = 10, size = 9 } },
	playhead = "busy",
	blocksAFK = true,
	blocksIdle = true,
	pause = { key = "camp", label = L["Camped"], order = 3, still = true },
})

DefineEvent(Kind.SLEEP, {
	name = L["Sleeping bag"],
	color = { 0.55, 0.62, 0.95 },
	shape = "span",
	configKey = "rest",
	keepsSession = true,
	pip = { shape = "circle", size = 7, legend = { order = 11, size = 9 } },
	playhead = "busy",
	blocksAFK = true,
	blocksIdle = true,
	pause = { key = "sleep", label = L["Slept"], order = 4, still = true },
})

DefineEvent(Kind.EAT, {
	name = L["Eating"],
	color = { 0.72, 0.58, 0.32 },
	shape = "span",
	pip = false,
	playhead = "busy",
	blocksAFK = true,
	blocksIdle = true,
	pause = { key = "eat", label = L["Eating"], order = 6, still = false },
})

DefineEvent(Kind.BOSS, {
	name = L["Boss"],
	color = { 1.00, 0.55, 0.20 },
	configKey = "instance",
	keepsSession = true,
	qualifiesCompany = true,
	pip = { shape = "ring", size = 9, milestone = true },
})

DefineEvent(Kind.FISH, {
	name = L["Fishing"],
	color = { 0.25, 0.55, 0.95 },
	shape = "span",
	config = { key = "fishing", page = "road", label = L["Fishing"], order = 8 },
	keepsSession = true,
	pip = { shape = "circle", size = 10, legend = { order = 6, size = 10 } },
	playhead = "fish",
	blocksAFK = true,
	blocksIdle = true,
	pause = { key = "fish", label = L["Fishing"], order = 5, still = false },
})

DefineEvent(Kind.IDLE, {
	name = L["Idle"],
	color = { 0.62, 0.62, 0.68 },
	shape = "span",
	config = { key = "idle", page = "road", label = L["Idle"], order = 6 },
	pip = false,
	playhead = "parked",
	-- Idle splits across instance doors and subtracts from Where; Viz handles it explicitly.
	pause = { key = "idle", label = L["Idle"], order = 1, still = false, custom = true },
})

DefineEvent(Kind.CRAFT, {
	name = L["Crafting"],
	color = { 0.90, 0.72, 0.28 },
	shape = "span",
	config = { key = "crafting", page = "road", label = L["Crafting"], order = 9 },
	keepsSession = true,
	pip = false,
	playhead = "busy",
	blocksAFK = true,
	blocksIdle = true,
	pause = { key = "craft", label = L["Crafting"], order = 7, still = false },
})

-- Ordered lists derived once from ns.EventSpec for Config, Replay, and Viz.
ns.PauseSpecs = {}
ns.LegendSpecs = {}
for _, spec in pairs(ns.EventSpec) do
	if spec.pause then
		ns.PauseSpecs[#ns.PauseSpecs + 1] = spec
	end
	if spec.pip and spec.pip.legend then
		ns.LegendSpecs[#ns.LegendSpecs + 1] = spec
	end
end

table.sort(ns.PauseSpecs, function(a, b)
	local ao, bo = a.pause.order or 999, b.pause.order or 999
	if ao ~= bo then
		return ao < bo
	end
	return a.kind < b.kind
end)

table.sort(ns.LegendSpecs, function(a, b)
	local ao, bo = a.pip.legend.order or 999, b.pip.legend.order or 999
	if ao ~= bo then
		return ao < bo
	end
	return a.kind < b.kind
end)

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
-- Well-Rested is earned-only: it stacks from a Cozy Sleeping Bag and sticks around
-- while you quest, so it must not count as "in the bag" or every pause between
-- pulls opens a sleep span.
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

-- Fishing is a channeled spell. Forever uses the Classic id; keep a few others.
local FISHING_SPELL = {
	[7620] = true,
	[7731] = true,
	[7732] = true,
	[18248] = true,
	[33095] = true,
	[51294] = true,
	[88868] = true,
	[110410] = true,
	[131474] = true,
	[131476] = true,
	[131490] = true,
	[158743] = true,
}

function ns.FishingSpell(spellID, name)
	if type(spellID) == "number" and not (issecretvalue and issecretvalue(spellID)) and FISHING_SPELL[spellID] then
		return true
	end
	if type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name == "Fishing" then
		return true
	end
	return false
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
