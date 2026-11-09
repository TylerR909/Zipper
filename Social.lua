local _, ns = ...

-- Roster only. How long you were together is the span list on the journey.
-- Quest turn-ins, kills, deaths, and instance doors are already on the path,
-- so those totals are counted when the replay asks. Objective ticks are not
-- stored: they cannot be rebuilt later, and they fire too often to keep.

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
		self.frame:SetScript("OnEvent", function()
			self:OnEvent()
		end)
	end
	local frame = self.frame
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	frame:RegisterEvent("GROUP_JOINED")
	frame:RegisterEvent("GROUP_LEFT")
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
	if ns.DB:CloseCompany(ns.DB:Now()) then
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
	self.tries = 0
	local now = ns.DB:Now()
	local joined, changed = ns.DB:ApplyRoster(members, now, self:MapID())
	if #joined > 0 then
		if not ns.GPS:Mark(ns.Kind.GROUP, #joined) then
			Notify()
		end
	elseif changed then
		Notify()
	end
end

function ns.Social:Start()
	self.active = true
	self:EnsureEvents()
	local now = ns.DB:Now()
	ns.DB:SealStaleCompany(now)
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
