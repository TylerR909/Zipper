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
}

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
