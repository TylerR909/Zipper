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

local function SpellName(spellID)
	if not IsPlainNumber(spellID) or not C_Spell or not C_Spell.GetSpellInfo then
		return nil
	end
	local info = C_Spell.GetSpellInfo(spellID)
	local name = info and info.name
	if type(name) ~= "string" or name == "" then
		return nil
	end
	if issecretvalue and issecretvalue(name) then
		return nil
	end
	return name
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

function ns.GPS:IsGhost()
	if not UnitIsGhost then
		return false
	end
	local ghost = UnitIsGhost("player")
	if ghost == nil or (issecretvalue and issecretvalue(ghost)) then
		return self.ghost and true or false
	end
	return ghost and true or false
end

function ns.GPS:SyncGhost()
	local ghost = self:IsGhost()
	if self.ghostReady and ghost == self.ghost then
		return
	end
	local changed = self.ghostReady and ghost ~= self.ghost
	self.ghost = ghost
	self.ghostReady = true
	if changed then
		self:ConsiderSample(0, true)
	end
end

function ns.GPS:TravelMode()
	if self.ghost then
		return ns.Travel.GHOST
	end
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

function ns.GPS:NoteReach()
	local session = ns.DB.session
	if not session or not UnitPosition then
		return
	end
	local px, py, _, instance = UnitPosition("player")
	if not IsPlainNumber(px) or not IsPlainNumber(py) or (issecretvalue and issecretvalue(instance)) then
		return
	end
	if not IsPlainNumber(session.ax) or not IsPlainNumber(session.ay) or session.ai == nil then
		session.ax = px
		session.ay = py
		session.ai = instance
		if type(session.reach) ~= "number" then
			session.reach = 0
		end
		return
	end
	if instance ~= session.ai then
		local far = ns.QUIET_YARDS or 250
		if (session.reach or 0) < far then
			session.reach = far
		end
		return
	end
	local dx = px - session.ax
	local dy = py - session.ay
	local dist = math.sqrt((dx * dx) + (dy * dy))
	if dist > (session.reach or 0) then
		session.reach = math.floor(dist + 0.5)
	end
end

function ns.GPS:ConsiderSample(minYards, force)
	local mapID, x, y = self:ReadPosition()
	if not mapID then
		return false
	end
	self:NoteReach()
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

function ns.GPS:ReconcileInstance()
	local inst = self:ReadInstance()
	self.instance = inst
	self.instanceReady = true
	local kind, extra, session = ns.DB:LastInstanceDoor()
	if kind == Kind.INSTANCE_ENTER and session and session ~= ns.DB.session then
		ns.DB:CloseInstance(session, extra)
		kind, extra, session = ns.DB:LastInstanceDoor()
	end
	local openHere = kind == Kind.INSTANCE_ENTER and session == ns.DB.session
	if inst and not openHere then
		self:Mark(Kind.INSTANCE_ENTER, inst)
	elseif not inst and openHere then
		self:Mark(Kind.INSTANCE_LEAVE, extra)
	end
end

function ns.GPS:SyncInstance()
	local inst = self:ReadInstance()
	if not self.instanceReady then
		self:ReconcileInstance()
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
	if self.restKind or self.meal then
		if self.afk then
			self.afk = false
			self:Mark(Kind.AFK_END, 0)
		end
		self.afkReady = true
		return
	end
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

local CAMPFIRE_AURA = 1283391
local REST_SECONDS = 60

function ns.GPS:AuraIndexSecret(index)
	-- GetBuffDataByIndex throws while auras are secret and the caller is tainted.
	-- The predicate is safe. inCombat is the fallback when that API is missing.
	if C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret then
		local secret = C_Secrets.ShouldUnitAuraIndexBeSecret("player", index)
		if secret == nil or (issecretvalue and issecretvalue(secret)) then
			return true
		end
		return secret and true or false
	end
	return self.inCombat and true or false
end

function ns.GPS:ReadRest()
	local camp, sleep, earned = false, false, false
	if self:AuraIndexSecret(1) then
		return nil
	end
	if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID and self:PlayerAura(CAMPFIRE_AURA) then
		camp = true
	end
	if not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then
		return camp, sleep, earned
	end
	for i = 1, 40 do
		if self:AuraIndexSecret(i) then
			return nil
		end
		local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
		if not aura then
			break
		end
		if issecretvalue and issecretvalue(aura) then
			return nil
		end
		local name = aura.name
		local spellID = aura.spellId
		if issecretvalue and issecretvalue(name) then
			name = nil
		end
		if not IsPlainNumber(spellID) then
			spellID = nil
		end
		local which, ready = ns.RestSignal(name, spellID)
		if which == "sleep" then
			sleep = true
			earned = earned or ready
		elseif which == "camp" then
			camp = true
			earned = earned or ready
		end
	end
	return camp, sleep, earned
end

function ns.GPS:PlayerAura(spellID)
	local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
	if not aura or (issecretvalue and issecretvalue(aura)) then
		return nil
	end
	return aura
end

function ns.GPS:BeginRest(kind)
	if self.restKind == kind then
		return
	end
	if self.restKind then
		self:EndRest()
	end
	if self.afk then
		self.afk = false
		self:Mark(Kind.AFK_END, 0)
	end
	self.restKind = kind
	self.restSince = nil
	self:Mark(kind, 0)
end

function ns.GPS:EndRest()
	local kind = self.restKind
	if not kind then
		return
	end
	self.restKind = nil
	self.restSince = nil
	self:Mark(kind, 1)
	self:SyncAFK()
end

function ns.GPS:StopRestWatch()
	if self.restTicker then
		self.restTicker:Cancel()
		self.restTicker = nil
	end
end

function ns.GPS:EnsureRestWatch()
	if self.restTicker or not C_Timer or not C_Timer.NewTicker then
		return
	end
	self.restTicker = C_Timer.NewTicker(5, function()
		if self.active then
			self:WatchRest()
		end
	end)
end

function ns.GPS:WatchRest()
	if not ns.Config:WantsKind(Kind.CAMP) then
		self.restSince = nil
		if self.restKind then
			self:EndRest()
		end
		self:StopRestWatch()
		return
	end
	local camp, sleep, earned = self:ReadRest()
	if camp == nil then
		return
	end
	if self.restKind == Kind.CAMP and not camp then
		self:EndRest()
	elseif self.restKind == Kind.SLEEP and not sleep then
		self:EndRest()
	end
	if not camp and not sleep then
		self.restSince = nil
		if not self.restKind then
			self:StopRestWatch()
		end
		return
	end
	self:EnsureRestWatch()
	if self.restKind or self.moving or self.onTaxi then
		if self.moving or self.onTaxi then
			self.restSince = nil
		end
		return
	end
	if earned then
		self:BeginRest(sleep and Kind.SLEEP or Kind.CAMP)
		return
	end
	local now = ns.DB:Now()
	if not self.restSince then
		self.restSince = now
	elseif now - self.restSince >= REST_SECONDS then
		self:BeginRest(sleep and Kind.SLEEP or Kind.CAMP)
	end
end

function ns.GPS:ReadMeal()
	if self:AuraIndexSecret(1) then
		return nil
	end
	if not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then
		return false
	end
	for i = 1, 40 do
		if self:AuraIndexSecret(i) then
			return nil
		end
		local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
		if not aura then
			break
		end
		if issecretvalue and issecretvalue(aura) then
			return nil
		end
		local name = aura.name
		if issecretvalue and issecretvalue(name) then
			name = nil
		end
		if ns.MealSignal(name) then
			return true
		end
	end
	return false
end

function ns.GPS:BeginMeal()
	if self.meal then
		return
	end
	if self.afk then
		self.afk = false
		self:Mark(Kind.AFK_END, 0)
	end
	self.meal = true
	self:Mark(Kind.EAT, 0)
end

function ns.GPS:EndMeal()
	if not self.meal then
		return
	end
	self.meal = false
	self:Mark(Kind.EAT, 1)
	self:SyncAFK()
end

function ns.GPS:WatchMeal()
	local eating = self:ReadMeal()
	if eating == nil then
		return
	end
	if eating then
		self:BeginMeal()
	else
		self:EndMeal()
	end
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
	self.summonerName = nil
	if C_SummonInfo and C_SummonInfo.GetSummonConfirmSummoner then
		local name = C_SummonInfo.GetSummonConfirmSummoner()
		if type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
			self.summonerName = name
		end
	end
end

function ns.GPS:CheckSummon()
	if not self.summonUntil then
		return
	end
	local now = ns.DB:Now()
	if now > self.summonUntil then
		self.summonUntil = nil
		self.summonerName = nil
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
		if self.summonerName then
			ns.DB:NoteSummoner(self.summonerName, ns.DB:Now())
			self.summonerName = nil
		end
	end
end

function ns.GPS:OnTrainer()
	if self.trainerSeen then
		return
	end
	self.trainerSeen = true
	local trainerType = 0
	if C_Trainer and C_Trainer.GetTrainerType then
		local value = C_Trainer.GetTrainerType()
		if IsPlainNumber(value) then
			trainerType = value
		end
	end
	local profession = 0
	local trades = Enum and Enum.TrainerType and Enum.TrainerType.Tradeskills
	if trainerType == trades and GetTrainerServiceSkillLine then
		local line = GetTrainerServiceSkillLine(1)
		if type(line) == "string" and not (issecretvalue and issecretvalue(line)) then
			profession = ns.ProfessionId(line)
		end
	end
	self:Mark(Kind.TRAINER, ns.DB:PackTrainer(trainerType, profession))
end

function ns.GPS:TargetClassification()
	if not UnitExists or not UnitExists("target") or not UnitClassification then
		return nil
	end
	local class = UnitClassification("target")
	if not class or (issecretvalue and issecretvalue(class)) then
		return nil
	end
	return class
end

function ns.GPS:TargetIsElite()
	local class = self:TargetClassification()
	return class == "elite" or class == "rareelite" or class == "worldboss"
end

function ns.GPS:TargetIsRare()
	local class = self:TargetClassification()
	return class == "rare" or class == "rareelite"
end

function ns.GPS:OnKill(attackerGUID, targetGUID)
	-- Forever forbids registering COMBAT_LOG_EVENT_UNFILTERED. PARTY_KILL is the
	-- kill-credit event, and it also fires for other people in the party.
	if not attackerGUID or (issecretvalue and issecretvalue(attackerGUID)) then
		return
	end
	local me = UnitGUID("player")
	if not me or (issecretvalue and issecretvalue(me)) or attackerGUID ~= me then
		return
	end
	if targetGUID and issecretvalue and issecretvalue(targetGUID) then
		targetGUID = nil
	end
	local mobID = ns.DB:CreatureID(targetGUID)
	local extra = ns.DB:PackKill(mobID, self:TargetIsElite(), self:TargetIsRare())
	if not self:Mark(Kind.KILL, extra) then
		ns.DB:AddKill()
	end
end

function ns.GPS:CombatLocked()
	if not InCombatLockdown then
		return false
	end
	local locked = InCombatLockdown()
	-- In combat this boolean can be secret. A tainted `if locked` then falls
	-- through, and the following RegisterEvent calls are forbidden.
	if issecretvalue and issecretvalue(locked) then
		return true
	end
	return locked and true or false
end

function ns.GPS:EnsureEvents()
	if self.eventsReady then
		return true
	end
	if self:CombatLocked() then
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
	frame:RegisterEvent("PLAYER_LEVEL_UP")
	frame:RegisterEvent("PLAYER_UNGHOST")
	frame:RegisterEvent("QUEST_ACCEPTED")
	frame:RegisterEvent("QUEST_TURNED_IN")
	frame:RegisterEvent("CONFIRM_SUMMON")
	frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	frame:RegisterEvent("TRAINER_SHOW")
	frame:RegisterEvent("TRAINER_UPDATE")
	frame:RegisterEvent("TRAINER_CLOSED")
	frame:RegisterEvent("UNIT_AURA")
	frame:RegisterEvent("PARTY_KILL")
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
	if ns.Social and ns.Social.active and not ns.Social.eventsReady then
		ns.Social:EnsureEvents()
	end
	ns.DB:NoteProgress()
	self:SyncGhost()
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
		self.restSince = nil
		if self.restKind then
			self:EndRest()
		end
		if self.meal then
			self:EndMeal()
		end
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
			self:SyncGhost()
		end
	elseif event == "PLAYER_DEAD" then
		self:Mark(Kind.DEATH, 0)
	elseif event == "PLAYER_LEVEL_UP" then
		local level = ...
		if type(level) == "number" and not (issecretvalue and issecretvalue(level)) then
			local stored = ns.DB:NoteLevelUp(level)
			self:Mark(Kind.LEVEL, level)
			if stored then
				local text, lo, hi = ns.DB:LevelRecapText(level)
				if text then
					ns:Print(text)
					local link = ns.DB:LevelChatLink(lo, hi)
					if link then
						ns:Print(link)
					end
				end
			end
		end
	elseif event == "PLAYER_UNGHOST" then
		self:SyncGhost()
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
		if not (issecretvalue and issecretvalue(unit)) and unit == "player" and IsPlainNumber(spellID) then
			if IsHearthSpell(spellID) then
				self.hearthUntil = ns.DB:Now() + 20
				self:Mark(Kind.HEARTH, spellID)
			else
				local name = SpellName(spellID)
				local cast = ns.TravelCast(name)
				if cast == "portal" then
					self:Mark(Kind.PORTAL, spellID)
				elseif cast == "ritual" then
					self:Mark(Kind.SUMMON, spellID)
				elseif spellID == 1307230 or (name and string.find(name, "Sleeping Bag", 1, true)) then
					self:EnsureRestWatch()
				end
			end
		end
	elseif event == "TRAINER_SHOW" then
		self.trainerSeen = false
		if C_Timer and C_Timer.After then
			C_Timer.After(0.2, function()
				if self.active then
					self:OnTrainer()
				end
			end)
		end
	elseif event == "TRAINER_UPDATE" then
		self:OnTrainer()
	elseif event == "TRAINER_CLOSED" then
		self.trainerSeen = false
	elseif event == "UNIT_AURA" then
		local unit = ...
		if unit == "player" and not (issecretvalue and issecretvalue(unit)) then
			self:WatchRest()
			self:WatchMeal()
		end
	elseif event == "PARTY_KILL" then
		local attackerGUID, targetGUID = ...
		self:OnKill(attackerGUID, targetGUID)
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

	self:SyncMount()
	self:SyncAFK()
	self:SyncTaxi()
	self:WatchMeal()

	if not self.ticker then
		self.ticker = C_Timer.NewTicker(1, function()
			self:Tick()
		end)
	end
	self:Tick()
end

function ns.GPS:Stop()
	self:EndMeal()
	self:EndRest()
	self:StopRestWatch()
	self.active = false
	self.moving = false
	ns.DB:NoteProgress()
	ns.DB:Touch(ns.DB:Now())
end
