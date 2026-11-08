local _, ns = ...

-- Path points come from movement and turning events, then get thrown away
-- unless the character actually went somewhere.
--
-- While traveling, a point is kept about every 2 seconds. In combat that
-- stretches to 3 seconds, because movement there is bursty. Stopping always
-- keeps a point, including when a fight starts mid-run. Releasing the mouse
-- after an out-of-combat arc can add one more point. PLAYER_STARTED_TURNING
-- is ignored. While standing, only a jump of about 40 yards is kept.

ns.GPS = {
	active = false,
	moving = false,
	onTaxi = false,
}

local Kind = ns.Kind
local TRAVEL_SECONDS = 2
local COMBAT_SECONDS = 3
local STEP_YARDS = 3
local STOP_YARDS = 2
local JUMP_YARDS = 40
local CORNER_FACING = 0.35
local InstanceByType = {
	party = ns.Instance.PARTY,
	raid = ns.Instance.RAID,
	pvp = ns.Instance.PVP,
	arena = ns.Instance.ARENA,
	scenario = ns.Instance.SCENARIO,
}

local function Notify()
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

local function CombatLogReader()
	if CombatLogGetCurrentEventInfo then
		return CombatLogGetCurrentEventInfo
	end
	if C_CombatLog and C_CombatLog.GetCurrentEventInfo then
		return C_CombatLog.GetCurrentEventInfo
	end
	if C_CombatLogInternal and C_CombatLogInternal.GetCurrentEventInfo then
		return C_CombatLogInternal.GetCurrentEventInfo
	end
end

local function IsHearthSpell(spellID)
	if spellID == 8690 or spellID == 556 then
		return true
	end
	if not spellID or not C_Spell or not C_Spell.GetSpellInfo then
		return false
	end
	local info = C_Spell.GetSpellInfo(spellID)
	local name = info and info.name
	return type(name) == "string" and string.find(name, "Hearth", 1, true) ~= nil
end

local function IsPlainNumber(value)
	if type(value) ~= "number" then
		return false
	end
	-- Combat can hand back a secret number. type() still says "number", and any
	-- compare or arithmetic on it errors while this addon is tainted.
	if issecretvalue and issecretvalue(value) then
		return false
	end
	return true
end

function ns.GPS:ReadPosition()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then
		return nil
	end
	local first, second = C_Map.GetPlayerMapPosition(mapID, "player")
	local x, y
	if type(first) == "number" then
		x, y = first, second
	elseif first then
		x, y = first.x, first.y
	end
	if not IsPlainNumber(x) or not IsPlainNumber(y) then
		return nil
	end
	if x <= 0 and y <= 0 then
		return nil
	end
	return mapID, x, y
end

function ns.GPS:FarEnough(mapID, x, y, minYards)
	if not self.lastMap or mapID ~= self.lastMap then
		return true
	end
	local px, py, _, instance = UnitPosition("player")
	if IsPlainNumber(px) and IsPlainNumber(py) and IsPlainNumber(self.lastWorldX) and not (issecretvalue and issecretvalue(instance)) and instance == self.lastInstance then
		local dx = px - self.lastWorldX
		local dy = py - self.lastWorldY
		return (dx * dx + dy * dy) >= (minYards * minYards)
	end
	local dx = x - (self.lastNormX or x)
	local dy = y - (self.lastNormY or y)
	local minNorm = 0.003
	if minYards <= STOP_YARDS then
		minNorm = 0.0005
	elseif minYards <= STEP_YARDS then
		minNorm = 0.0008
	elseif minYards >= JUMP_YARDS then
		minNorm = 0.008
	end
	return (dx * dx + dy * dy) >= (minNorm * minNorm)
end

function ns.GPS:NoteSampled()
	self.lastSampleAt = GetTime()
end

function ns.GPS:Due(seconds)
	if not self.lastSampleAt then
		return true
	end
	return (GetTime() - self.lastSampleAt) >= seconds
end

function ns.GPS:RememberWorld()
	local px, py, _, instance = UnitPosition("player")
	if IsPlainNumber(px) and IsPlainNumber(py) and not (issecretvalue and issecretvalue(instance)) then
		self.lastWorldX = px
		self.lastWorldY = py
		self.lastInstance = instance
	end
	if GetPlayerFacing then
		local facing = GetPlayerFacing()
		if IsPlainNumber(facing) then
			self.lastFacing = facing
		end
	end
end

function ns.GPS:TravelMode()
	if self.onTaxi then
		return ns.Travel.FLIGHT
	end
	if self.mounted then
		return ns.Travel.MOUNT
	end
	return ns.Travel.FOOT
end

function ns.GPS:SpeedPercent()
	if not GetUnitSpeed then
		return self.lastSpeed or 100
	end
	local current, run = GetUnitSpeed("player")
	if not IsPlainNumber(current) or not IsPlainNumber(run) or run <= 0 then
		return self.lastSpeed or 100
	end
	local pct = math.floor((current / run) * 100 + 0.5)
	if pct < 0 then
		pct = 0
	elseif pct > 1000 then
		pct = 1000
	end
	self.lastSpeed = pct
	return pct
end

function ns.GPS:ConsiderSample(minYards, force)
	local mapID, x, y = self:ReadPosition()
	if not mapID then
		return false
	end
	if not force and not self:FarEnough(mapID, x, y, minYards) then
		return false
	end
	local now = ns.DB:Now()
	local stored = ns.DB:AddSample(mapID, x, y, now, self:TravelMode(), self:SpeedPercent())
	self.lastMap = mapID
	self.lastNormX = x
	self.lastNormY = y
	self:RememberWorld()
	if stored then
		self:NoteSampled()
		Notify()
	end
	return stored
end

function ns.GPS:SampleClock()
	local seconds = TRAVEL_SECONDS
	if self.inCombat and not self.onTaxi then
		seconds = COMBAT_SECONDS
	end
	if not self:Due(seconds) then
		return false
	end
	return self:ConsiderSample(STEP_YARDS, false)
end

function ns.GPS:Mark(kind, extra)
	if not ns.Config:WantsKind(kind) then
		return true
	end
	self:ConsiderSample(0, true)
	local mapID, x, y = self:ReadPosition()
	if not mapID then
		return false
	end
	ns.DB:AddEvent(kind, mapID, x, y, ns.DB:Now(), extra or 0)
	Notify()
	return true
end

function ns.GPS:ReadInstance()
	local inside, kind = IsInInstance()
	if not inside or kind == nil or kind == "none" then
		return nil
	end
	return InstanceByType[kind] or ns.Instance.OTHER
end

function ns.GPS:SyncInstance()
	local inst = self:ReadInstance()
	if not self.instanceReady then
		self.instance = inst
		if self.continued or not inst then
			self.instanceReady = true
			return
		end
		if self:Mark(Kind.INSTANCE_ENTER, inst) then
			self.instanceReady = true
		end
		return
	end
	if inst == self.instance then
		return
	end
	if self.instance then
		self:Mark(Kind.INSTANCE_LEAVE, self.instance)
	end
	self.instance = inst
	if inst then
		self:Mark(Kind.INSTANCE_ENTER, inst)
	end
end

function ns.GPS:SyncTaxi()
	local taxi = UnitOnTaxi("player") and true or false
	if self.taxiReady ~= true then
		self.onTaxi = taxi
		if self.continued or not taxi then
			self.taxiReady = true
			return
		end
		if self:Mark(Kind.FLIGHT_START, 0) then
			self.taxiReady = true
		end
		return
	end
	if taxi == self.onTaxi then
		return
	end
	self.onTaxi = taxi
	self:Mark(taxi and Kind.FLIGHT_START or Kind.FLIGHT_END, 0)
end

function ns.GPS:SyncMount()
	local mounted = IsMounted() and true or false
	if self.mountReady ~= true then
		self.mounted = mounted
		self.mountReady = true
		return
	end
	if mounted == self.mounted then
		return
	end
	self.mounted = mounted
	self:Mark(mounted and Kind.MOUNT or Kind.DISMOUNT, 0)
end

function ns.GPS:SyncAFK()
	local afk = UnitIsAFK("player") and true or false
	if self.afkReady ~= true then
		self.afk = afk
		if self.continued or not afk then
			self.afkReady = true
			return
		end
		if self:Mark(Kind.AFK_START, 0) then
			self.afkReady = true
		end
		return
	end
	if afk == self.afk then
		return
	end
	self.afk = afk
	self:Mark(afk and Kind.AFK_START or Kind.AFK_END, 0)
end

function ns.GPS:OnStopTurning()
	if self.inCombat or (not self.moving and not self.onTaxi) then
		return
	end
	if GetPlayerFacing and self.lastFacing then
		local facing = GetPlayerFacing()
		if IsPlainNumber(facing) and IsPlainNumber(self.lastFacing) then
			local delta = math.abs(facing - self.lastFacing)
			if delta > math.pi then
				delta = (math.pi * 2) - delta
			end
			if delta < CORNER_FACING then
				return
			end
		end
	end
	self:ConsiderSample(STEP_YARDS, false)
end

function ns.GPS:OnCombat(entered)
	local was = self.inCombat and true or false
	self.inCombat = entered and true or false
	if was == self.inCombat then
		return
	end
	if self.moving or self.onTaxi then
		self:ConsiderSample(STEP_YARDS, false)
	end
end

function ns.GPS:OnConfirmSummon()
	self.summonUntil = ns.DB:Now() + 120
	local px, py, _, instance = UnitPosition("player")
	if IsPlainNumber(px) and IsPlainNumber(py) and not (issecretvalue and issecretvalue(instance)) then
		self.summonX, self.summonY, self.summonInstance = px, py, instance
	else
		self.summonX = nil
	end
	self.summonMap = C_Map.GetBestMapForUnit("player")
end

function ns.GPS:CheckSummon()
	if not self.summonUntil then
		return
	end
	local now = ns.DB:Now()
	if now > self.summonUntil then
		self.summonUntil = nil
		return
	end
	if self.hearthUntil and now < self.hearthUntil then
		return
	end
	if UnitIsGhost and UnitIsGhost("player") then
		return
	end
	if UnitOnTaxi("player") then
		return
	end

	local jumped = false
	local px, py, _, instance = UnitPosition("player")
	if IsPlainNumber(px) and IsPlainNumber(py) and IsPlainNumber(self.summonX) and IsPlainNumber(self.summonY) and not (issecretvalue and issecretvalue(instance)) and instance == self.summonInstance then
		local dx = px - self.summonX
		local dy = py - self.summonY
		jumped = (dx * dx + dy * dy) >= (80 * 80)
	else
		local mapID = C_Map.GetBestMapForUnit("player")
		jumped = mapID and self.summonMap and mapID ~= self.summonMap
	end
	if jumped then
		self.summonUntil = nil
		self:Mark(Kind.SUMMON, 0)
	end
end

function ns.GPS:OnKill()
	local read = CombatLogReader()
	if not read then
		return
	end
	local ok, _, subevent, _, sourceGUID = pcall(read)
	if not ok or subevent ~= "PARTY_KILL" then
		return
	end
	if sourceGUID ~= UnitGUID("player") then
		return
	end
	ns.DB:AddKill()
end

function ns.GPS:EnsureEvents()
	if self.eventsReady then
		return true
	end
	-- RegisterEvent is protected during combat lockdown. Logging back into a
	-- fight makes the first PLAYER_ENTERING_WORLD hit that case.
	if InCombatLockdown and InCombatLockdown() then
		return false
	end
	if not self.frame then
		self.frame = CreateFrame("Frame")
		self.frame:SetScript("OnEvent", function(_, event, ...)
			self:OnEvent(event, ...)
		end)
	end
	local frame = self.frame
	frame:RegisterEvent("PLAYER_STARTED_MOVING")
	frame:RegisterEvent("PLAYER_STOPPED_MOVING")
	frame:RegisterEvent("PLAYER_STOPPED_TURNING")
	frame:RegisterEvent("PLAYER_REGEN_DISABLED")
	frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	frame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
	frame:RegisterEvent("PLAYER_FLAGS_CHANGED")
	frame:RegisterEvent("PLAYER_DEAD")
	frame:RegisterEvent("QUEST_ACCEPTED")
	frame:RegisterEvent("QUEST_TURNED_IN")
	frame:RegisterEvent("CONFIRM_SUMMON")
	frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	frame:RegisterEvent("PLAYER_CONTROL_LOST")
	frame:RegisterEvent("PLAYER_CONTROL_GAINED")
	self.eventsReady = true
	return true
end

function ns.GPS:Tick()
	if not self.active then
		return
	end
	if not self.eventsReady then
		self:EnsureEvents()
	end
	ns.DB:NoteProgress()
	self:SyncTaxi()
	self:SyncInstance()
	self:CheckSummon()
	if self.needAnchor then
		if self:ReadPosition() then
			self:ConsiderSample(0, true)
			self.needAnchor = false
		end
		return
	end
	if self.moving or self.onTaxi then
		self:SampleClock()
	else
		self:ConsiderSample(JUMP_YARDS, false)
	end
end

function ns.GPS:OnEvent(event, ...)
	if not self.active then
		return
	end
	if event == "PLAYER_STARTED_MOVING" then
		self.moving = true
		self:ConsiderSample(STOP_YARDS, false)
	elseif event == "PLAYER_STOPPED_MOVING" then
		self.moving = false
		self:ConsiderSample(STOP_YARDS, false)
	elseif event == "PLAYER_STOPPED_TURNING" then
		self:OnStopTurning()
	elseif event == "PLAYER_REGEN_DISABLED" then
		self:OnCombat(true)
	elseif event == "PLAYER_REGEN_ENABLED" then
		self:OnCombat(false)
	elseif event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
		self:SyncMount()
	elseif event == "PLAYER_FLAGS_CHANGED" then
		local unit = ...
		if unit == "player" then
			self:SyncAFK()
		end
	elseif event == "PLAYER_DEAD" then
		self:Mark(Kind.DEATH, 0)
	elseif event == "QUEST_ACCEPTED" then
		local questID = ...
		self:Mark(Kind.QUEST_ACCEPT, questID or 0)
	elseif event == "QUEST_TURNED_IN" then
		local questID = ...
		self:Mark(Kind.QUEST_TURNIN, questID or 0)
	elseif event == "CONFIRM_SUMMON" then
		self:OnConfirmSummon()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit == "player" and IsHearthSpell(spellID) then
			self.hearthUntil = ns.DB:Now() + 20
			self:Mark(Kind.HEARTH, spellID or 0)
		end
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		self:OnKill()
	elseif event == "PLAYER_CONTROL_LOST" or event == "PLAYER_CONTROL_GAINED" then
		self:SyncTaxi()
	end
end

function ns.GPS:Start(continued)
	self.active = true
	self.continued = continued and true or false
	local moving = false
	if IsPlayerMoving then
		moving = IsPlayerMoving() and true or false
	end
	self.moving = moving
	self.inCombat = UnitAffectingCombat and UnitAffectingCombat("player") and true or false
	self.needAnchor = not self.continued
	self.instanceReady = false
	self.taxiReady = false
	self.mountReady = false
	self.afkReady = false

	local session = ns.DB:Current()
	local track = session and ns.DB:Track(session) or nil
	local n = track and #track.t or 0
	if n > 0 then
		self.lastMap = track.m[n]
		self.lastNormX = track.x[n] / ns.COORD_SCALE
		self.lastNormY = track.y[n] / ns.COORD_SCALE
	else
		self.lastMap = nil
	end
	self.lastWorldX = nil
	if self.continued then
		self:RememberWorld()
	end

	self:EnsureEvents()

	self:SyncMount()
	self:SyncAFK()
	self:SyncTaxi()

	if not self.ticker then
		self.ticker = C_Timer.NewTicker(1, function()
			self:Tick()
		end)
	end
	self:Tick()
end

function ns.GPS:Stop()
	self.active = false
	self.moving = false
	ns.DB:NoteProgress()
	ns.DB:Touch(ns.DB:Now())
end
