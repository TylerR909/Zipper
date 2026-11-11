local _, ns = ...

-- Roster only. A person is saved after a quest, a finished objective, a kill,
-- a death, or an instance while they were actually with you. Being invited
-- is not enough, and neither is a party member across the zone.
-- "With you" is about 250 yards, the same bubble the party frames use.
-- Stepping past it for a minute and a half still counts. A different zone does not,
-- unless they are visibly here and the zone text is just stale. Visibility alone
-- is not near enough: party members stay "visible" far across the map.
-- Objective ticks are not stored. Finishing one only marks the span as worth keeping.
--
-- A reload does not guess who joined while the UI was down. People already
-- worth saving are the same stretch if they are still here within a few minutes.
-- Anyone new starts when the roster can first be read.

ns.Social = {
	active = false,
}

local DEBOUNCE = 0.4
local MAX_TRIES = 5
-- Party frames treat "nearby" as 250 yards (DISTANCE_THRESHOLD_SQUARED).
local NEAR_YARDS = 250
local NEAR_YARDS_SQUARED = NEAR_YARDS * NEAR_YARDS
-- Long enough to run ahead of the group. Not long enough to be across the zone.
local NEAR_GRACE = 90

local function PlainString(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	return value
end

local function PlainNumber(value)
	if type(value) ~= "number" then
		return nil
	end
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	return value
end

local function PlainBool(value)
	if value == nil or (issecretvalue and issecretvalue(value)) then
		return nil
	end
	return value and true or false
end

local function Notify()
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

function ns.Social:EnsureEvents()
	if self.eventsReady then
		return true
	end
	if ns.GPS:CombatLocked() then
		return false
	end
	if not self.frame then
		self.frame = CreateFrame("Frame")
		self.frame:SetScript("OnEvent", function(_, event, ...)
			if event == "QUEST_LOG_CRITERIA_UPDATE" then
				self:OnCriteria(...)
			elseif event == "UNIT_DISTANCE_CHECK_UPDATE" then
				self:OnDistance(...)
			else
				self:OnEvent()
			end
		end)
	end
	local frame = self.frame
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	frame:RegisterEvent("GROUP_JOINED")
	frame:RegisterEvent("GROUP_LEFT")
	frame:RegisterEvent("QUEST_LOG_CRITERIA_UPDATE")
	frame:RegisterEvent("UNIT_DISTANCE_CHECK_UPDATE")
	self.eventsReady = true
	return true
end

function ns.Social:OnEvent()
	if not self.active then
		return
	end
	self.tries = 0
	self:Schedule()
end

function ns.Social:Schedule()
	if self.waiting or not C_Timer or not C_Timer.After then
		return
	end
	self.waiting = true
	C_Timer.After(DEBOUNCE, function()
		self.waiting = false
		if self.active then
			self:Sync()
		end
	end)
end

function ns.Social:Disable()
	ns.DB:CloseCompany(ns.DB:Now())
	ns.DB:PruneIdleCompany(false)
	Notify()
end

function ns.Social:Remember(members, joined, now)
	self.seen = self.seen or {}
	local mapID, x, y
	if ns.GPS and ns.GPS.ReadPosition then
		mapID, x, y = ns.GPS:ReadPosition()
	end
	if not mapID then
		mapID = self:MapID()
		x, y = x or 0, y or 0
	end
	local fresh = {}
	for i = 1, #joined do
		fresh[joined[i]] = true
	end
	for guid, info in pairs(members) do
		local row = self.seen[guid]
		if type(row) ~= "table" then
			row = {}
			self.seen[guid] = row
		end
		if type(info.n) == "string" and info.n ~= "" then
			row.n = info.n
		end
		if type(info.c) == "string" and info.c ~= "" then
			row.c = info.c
		end
		if type(info.lv) == "number" and info.lv > 0 and type(row.lv) ~= "number" then
			row.lv = info.lv
		end
		if type(info.z) == "string" and info.z ~= "" then
			row.zone = info.z
		end
		if fresh[guid] or type(row.t) ~= "number" then
			row.t = now
			row.map = mapID or 0
			row.x = x
			row.y = y
		end
		local people = ZipperDB and ZipperDB.people
		if type(people) == "table" and type(people[guid]) == "table" then
			ns.DB:TouchPerson(guid, row, row.t or now, row.map)
		end
	end
end

function ns.Social:Recall(guid)
	local row = self.seen and self.seen[guid]
	if type(row) ~= "table" then
		return nil
	end
	return row, row.map, row.x, row.y
end

function ns.Social:OnCriteria(questID, treeID, _, fulfilled, required)
	if not self.active or not ns.Config:Enabled("party") then
		return
	end
	fulfilled = PlainNumber(fulfilled)
	if not fulfilled then
		return
	end
	questID = PlainNumber(questID) or 0
	treeID = PlainNumber(treeID) or 0
	required = PlainNumber(required)
	local key = questID .. ":" .. treeID
	self.progress = self.progress or {}
	local previous = self.progress[key]
	self.progress[key] = fulfilled
	-- The first sight of a criteria is a baseline. Login replays objectives
	-- that were already finished, and those must not count as a new moment.
	if not self.synced or type(previous) ~= "number" or fulfilled <= previous then
		return
	end
	if not required or required <= 0 or fulfilled < required then
		return
	end
	if ns.DB:CreditCompany(ns.DB:Now()) then
		Notify()
	end
end

function ns.Social:PlayerZone()
	local zone = GetRealZoneText and PlainString(GetRealZoneText())
	if not zone and GetZoneText then
		zone = PlainString(GetZoneText())
	end
	return zone
end

function ns.Social:InsideInstance()
	if not IsInInstance then
		return false
	end
	return PlainBool(IsInInstance()) == true
end

function ns.Social:RosterZones()
	local zones = {}
	if not GetRaidRosterInfo or not GetNumGroupMembers then
		return zones
	end
	local count = PlainNumber(GetNumGroupMembers())
	if not count or count <= 0 then
		return zones
	end
	for i = 1, count do
		local name, _, _, _, _, _, zone = GetRaidRosterInfo(i)
		name = PlainString(name)
		zone = PlainString(zone)
		if name and zone then
			zones[name] = zone
		end
	end
	return zones
end

function ns.Social:ZoneFor(zones, name)
	if type(name) ~= "string" or name == "" or type(zones) ~= "table" then
		return nil
	end
	if zones[name] then
		return zones[name]
	end
	local bare = name:match("^[^-]+")
	if bare and zones[bare] then
		return zones[bare]
	end
	for listed, zone in pairs(zones) do
		if listed == name or listed:sub(1, #name + 1) == name .. "-" then
			return zone
		end
		if bare and (listed == bare or listed:sub(1, #bare + 1) == bare .. "-") then
			return zone
		end
	end
	return nil
end

function ns.Social:UnitFor(guid)
	if type(guid) ~= "string" or not UnitGUID then
		return nil
	end
	local function check(token)
		if PlainString(UnitGUID(token)) == guid then
			return token
		end
		return nil
	end
	if IsInRaid and PlainBool(IsInRaid()) then
		local count = GetNumGroupMembers and PlainNumber(GetNumGroupMembers()) or 0
		for i = 1, count or 0 do
			local token = check("raid" .. i)
			if token then
				return token
			end
		end
		return nil
	end
	local count = GetNumSubgroupMembers and PlainNumber(GetNumSubgroupMembers()) or 0
	for i = 1, count or 0 do
		local token = check("party" .. i)
		if token then
			return token
		end
	end
	return nil
end

-- Inside the ~40-yard party range check. UnitIsVisible is not used here:
-- party and raid members stay "visible" across the zone.
function ns.Social:LiveHere(unit)
	if not unit or not UnitInRange then
		return false
	end
	local inRange, checked = UnitInRange(unit)
	if PlainBool(checked) ~= true then
		return false
	end
	return PlainBool(inRange) == true
end

function ns.Social:ReadDistance(unit, reported)
	local near = PlainBool(reported)
	if near ~= nil then
		return near
	end
	if self:InsideInstance() or not UnitDistanceSquared or not unit then
		return nil
	end
	local distance, checked = UnitDistanceSquared(unit)
	if PlainBool(checked) ~= true or not PlainNumber(distance) then
		return nil
	end
	return distance < NEAR_YARDS_SQUARED
end

function ns.Social:ZoneStale(guid)
	local unit = self:UnitFor(guid)
	return unit and UnitIsVisible and PlainBool(UnitIsVisible(unit)) == true or false
end

-- True when this person should share the moment and the clock.
-- Outdoors that means a real distance reading (or the short grace after one).
-- Inside an instance the matching zone is the guard, because distance fails.
function ns.Social:NearEnough(guid)
	self:SampleDistance(guid)
	local unit = self:UnitFor(guid)
	if self:LiveHere(unit) then
		return true
	end
	local row = self.seen and self.seen[guid]
	local near = row and row.near
	-- Indoor distance checks are not usable. The instance zone is the guard.
	if near == false and self:InsideInstance() then
		near = nil
	end
	if near == true then
		return true
	end
	local playerZone = self:PlayerZone()
	local memberZone = row and PlainString(row.zone)
	local zoneDiffers = playerZone and memberZone and playerZone ~= memberZone
	-- Zone text can lag. Someone still visible may be here despite a stale name.
	local zoneBlocks = zoneDiffers and not self:ZoneStale(guid)
	if near == false and type(row.nearAt) == "number" then
		local age = ns.DB:Now() - row.nearAt
		if age <= NEAR_GRACE and not zoneBlocks then
			return true
		end
		if age > NEAR_GRACE then
			return false
		end
	end
	if zoneBlocks then
		return false
	end
	if self:InsideInstance() then
		return true
	end
	-- Outdoors with no usable distance reading: do not assume they are beside you.
	return false
end

-- Proven beside you, so a later leave keeps the stretch instead of discarding it.
-- Same zone outdoors is not enough: that is how a far roster slot used to stick.
-- Inside an instance the matching zone is the proof, because distance fails.
function ns.Social:Confirmed(guid)
	local row = self.seen and self.seen[guid]
	if type(row) == "table" and row.confirmed then
		return true
	end
	if row and row.near == true then
		return true
	end
	if self:LiveHere(self:UnitFor(guid)) then
		return true
	end
	if not self:InsideInstance() then
		return false
	end
	local playerZone = self:PlayerZone()
	local memberZone = row and PlainString(row.zone)
	return playerZone and memberZone and playerZone == memberZone or false
end

function ns.Social:OnDistance(unit, isInDistance)
	if not self.active or not ns.Config:Enabled("party") then
		return
	end
	unit = PlainString(unit)
	if not unit or not UnitGUID then
		return
	end
	local guid = PlainString(UnitGUID(unit))
	if not guid then
		return
	end
	local near = self:ReadDistance(unit, isInDistance)
	if near == nil then
		return
	end
	self.seen = self.seen or {}
	local row = self.seen[guid]
	if type(row) ~= "table" then
		row = {}
		self.seen[guid] = row
	end
	local was = row.near
	row.near = near
	if near == false then
		if was ~= false then
			row.nearAt = ns.DB:Now()
		end
	else
		row.nearAt = ns.DB:Now()
	end
	if was == near then
		return
	end
	self:RefreshPresence()
	if near == false then
		self:ScheduleGrace()
	end
end

function ns.Social:ScheduleGrace()
	if self.graceWaiting or not C_Timer or not C_Timer.After then
		return
	end
	self.graceWaiting = true
	C_Timer.After(NEAR_GRACE + 0.2, function()
		self.graceWaiting = false
		if self.active then
			self:RefreshPresence()
		end
	end)
end

function ns.Social:SampleDistance(guid)
	if self:InsideInstance() then
		return
	end
	local unit = self:UnitFor(guid)
	local near = self:ReadDistance(unit, nil)
	if near == nil then
		return
	end
	self.seen = self.seen or {}
	local row = self.seen[guid]
	if type(row) ~= "table" then
		row = {}
		self.seen[guid] = row
	end
	if row.near == near then
		return
	end
	row.near = near
	row.nearAt = ns.DB:Now()
	if near == false then
		self:ScheduleGrace()
	end
end

function ns.Social:RefreshPresence()
	local members = self.lastMembers
	if type(members) ~= "table" or not self.active then
		return
	end
	local now = ns.DB:Now()
	local present = {}
	local closed = false
	for guid, info in pairs(members) do
		self:SampleDistance(guid)
		if self:NearEnough(guid) then
			present[guid] = info
			local row = self.seen and self.seen[guid]
			if type(row) == "table" and self:Confirmed(guid) then
				row.confirmed = true
			end
		elseif self:Confirmed(guid) then
			if ns.DB:CloseMember(guid, now) then
				closed = true
			end
		elseif ns.DB:DropOpen(guid) then
			closed = true
		end
	end
	local joined, changed = ns.DB:ApplyRoster(present, now)
	self:Remember(members, joined, now)
	if closed then
		ns.DB:PruneIdleCompany(true)
	end
	if changed or closed then
		Notify()
	end
end

-- party1..partyN excludes the player. raid1..raidN includes them.
function ns.Social:Snapshot()
	local grouped = IsInGroup and PlainBool(IsInGroup())
	if grouped == nil then
		return nil, false
	end
	if not grouped then
		return {}, true
	end
	local raid = IsInRaid and PlainBool(IsInRaid())
	if raid == nil then
		return nil, false
	end
	local units = {}
	if raid then
		local count = GetNumGroupMembers and PlainNumber(GetNumGroupMembers())
		if not count or count <= 0 then
			return nil, false
		end
		for i = 1, count do
			units[#units + 1] = "raid" .. i
		end
	else
		local count = GetNumSubgroupMembers and PlainNumber(GetNumSubgroupMembers())
		if not count then
			local total = GetNumGroupMembers and PlainNumber(GetNumGroupMembers())
			if total then
				count = math.max(0, total - 1)
			end
		end
		if not count or count <= 0 then
			return nil, false
		end
		for i = 1, count do
			units[#units + 1] = "party" .. i
		end
	end
	local members = {}
	local zones = self:RosterZones()
	local mine = UnitGUID and PlainString(UnitGUID("player"))
	local home = GetRealmName and PlainString(GetRealmName())
	for i = 1, #units do
		local unit = units[i]
		if not UnitExists or PlainBool(UnitExists(unit)) ~= true then
			return nil, false
		end
		local selfUnit = UnitIsUnit and PlainBool(UnitIsUnit(unit, "player"))
		local guid = UnitGUID and PlainString(UnitGUID(unit))
		if selfUnit or (guid and mine and guid == mine) then
			-- The raid list includes the player. A party list does not.
		elseif not guid then
			return nil, false
		else
			local name, realm = UnitName(unit)
			name = PlainString(name)
			realm = PlainString(realm)
			if name and realm and realm ~= home then
				name = name .. "-" .. realm
			end
			local _, classFile = UnitClass(unit)
			classFile = PlainString(classFile)
			local level = UnitLevel and PlainNumber(UnitLevel(unit)) or 0
			if not level or level < 1 then
				level = 0
			end
			members[guid] = {
				n = name,
				c = classFile,
				lv = level,
				z = self:ZoneFor(zones, name),
			}
		end
	end
	return members, true
end

function ns.Social:MapID()
	if not C_Map or not C_Map.GetBestMapForUnit then
		return 0
	end
	local mapID = C_Map.GetBestMapForUnit("player")
	if not PlainNumber(mapID) then
		return 0
	end
	return mapID
end

function ns.Social:Sync()
	if not self.active then
		return
	end
	if not ns.Config:Enabled("party") then
		self:Disable()
		return
	end
	local members, ready = self:Snapshot()
	if not ready then
		self.tries = (self.tries or 0) + 1
		if self.tries <= MAX_TRIES then
			self:Schedule()
		end
		return
	end
	-- Right after login an empty roster is often just late, not a real leave.
	-- Wait out a few tries before closing the people who were already saved.
	if not next(members) and not self.settled then
		self.tries = (self.tries or 0) + 1
		if self.tries <= MAX_TRIES then
			self:Schedule()
			return
		end
	end
	self.settled = true
	self.synced = true
	self.tries = 0
	self:NoteZones(members)
	self.lastMembers = members
	self:RefreshPresence()
end

function ns.Social:NoteZones(members)
	self.seen = self.seen or {}
	for guid, info in pairs(members) do
		if type(info.z) == "string" and info.z ~= "" then
			local row = self.seen[guid]
			if type(row) ~= "table" then
				row = {}
				self.seen[guid] = row
			end
			row.zone = info.z
		end
	end
end

function ns.Social:Start()
	self.active = true
	self:EnsureEvents()
	local now = ns.DB:Now()
	self.settled = false
	self.synced = false
	ns.DB:SealStaleCompany(now)
	ns.DB:PruneIdleCompany(false)
	if not ns.Config:Enabled("party") then
		self:Disable()
		return
	end
	self.tries = 0
	self:Schedule()
end

function ns.Social:Stop()
	self.active = false
	ns.DB:CloseCompany(ns.DB:Now())
end
