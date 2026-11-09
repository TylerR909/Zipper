local _, ns = ...

-- Roster only. A person is saved after a quest, a finished objective, a kill,
-- a death, or an instance while their span covers that moment. Being invited
-- is not enough, and the logout save drops anyone who never crossed that line.
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
	local now = ns.DB:Now()
	local joined, changed = ns.DB:ApplyRoster(members, now)
	self:Remember(members, joined, now)
	if changed then
		Notify()
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
