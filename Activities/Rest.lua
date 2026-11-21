local _, ns = ...

local Kind = ns.Kind
local REST_SECONDS = 60
-- Sleeping-bag cast arms a short window; Well-Rested alone must not keep it open.
local SLEEP_ARM_SECONDS = 180

local Rest = {
	id = "rest",
	events = {
		"UNIT_AURA",
		"UNIT_SPELLCAST_SUCCEEDED",
	},
}

function Rest:Read(gps)
	local camp, sleep, earned = gps:ReadBuffSignals()
	if camp == nil then
		return nil
	end
	return camp, sleep, earned
end

function Rest:BagArmed(now)
	if not self.sleepArmed then
		return false
	end
	now = now or ns.DB:Now()
	if now - self.sleepArmed > SLEEP_ARM_SECONDS then
		self.sleepArmed = nil
		return false
	end
	return true
end

function Rest:StopWatch()
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end
end

function Rest:EnsureWatch(gps)
	if self.ticker or not C_Timer or not C_Timer.NewTicker then
		return
	end
	self.ticker = C_Timer.NewTicker(5, function()
		if gps.active then
			self:Watch(gps)
		end
	end)
end

function Rest:ArmSleepBag(gps)
	self.sleepArmed = ns.DB:Now()
	self:EnsureWatch(gps)
end

function Rest:Begin(gps, kind)
	if self.restKind == kind then
		return
	end
	if self.restKind then
		self:End(gps)
	end
	if gps:BeginSpan(kind) then
		self.restKind = kind
		self.restSince = nil
	end
end

function Rest:End(gps)
	local kind = self.restKind
	if not kind then
		return
	end
	self.restKind = nil
	self.restSince = nil
	if kind == Kind.SLEEP then
		self.sleepArmed = nil
	end
	gps:EndSpan(kind)
end

function Rest:Watch(gps)
	if not ns.Config:WantsKind(Kind.CAMP) then
		self.restSince = nil
		self.sleepArmed = nil
		if self.restKind then
			self:End(gps)
		end
		self:StopWatch()
		return
	end
	local camp, sleep, earned = self:Read(gps)
	if camp == nil then
		return
	end
	local now = ns.DB:Now()
	local sleepProx = sleep or self:BagArmed(now)
	-- Camp ends when you leave the fire. Sleep ends on move/combat, not when
	-- Well-Rested flickers, or bag-armed windows would restart every pause.
	if self.restKind == Kind.CAMP and not camp then
		self:End(gps)
	end
	if not camp and not sleepProx then
		self.restSince = nil
		if not self.restKind then
			self:StopWatch()
		end
		return
	end
	self:EnsureWatch(gps)
	if gps.moving or gps.onTaxi or gps.inCombat then
		self.restSince = nil
		if self.restKind then
			self:End(gps)
		end
		return
	end
	if self.restKind then
		return
	end
	-- Earned camp benefits only start a camp while you are still at the fire.
	-- Sleeping-bag / Well-Rested always needs the stillness timer so a recent
	-- bag cast cannot spam starts between pulls.
	if earned and camp then
		self:Begin(gps, Kind.CAMP)
		return
	end
	local want = camp and Kind.CAMP or (sleepProx and Kind.SLEEP) or nil
	if not want then
		return
	end
	if not self.restSince then
		self.restSince = now
	elseif now - self.restSince >= REST_SECONDS then
		self:Begin(gps, want)
		if want == Kind.SLEEP then
			self.sleepArmed = nil
		end
	end
end

function Rest:Interrupt(gps)
	self.restSince = nil
	if self.restKind then
		self:End(gps)
	end
end

function Rest:OnEvent(gps, event, ...)
	if event == "UNIT_AURA" then
		local unit, updateInfo = ...
		if unit == "player" and not (issecretvalue and issecretvalue(unit)) and gps:AuraChanged(updateInfo) then
			self:Watch(gps)
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if not (issecretvalue and issecretvalue(unit)) and unit == "player" and gps:PlainNumber(spellID) then
			local name = gps:SpellName(spellID)
			if spellID == 1307230 or (name and string.find(name, "Sleeping Bag", 1, true)) then
				self:ArmSleepBag(gps)
			end
		end
	end
end

function Rest:OnMoveStart(gps)
	self:Interrupt(gps)
end

function Rest:OnCombat(gps, entered)
	if entered then
		self:Interrupt(gps)
	end
end

function Rest:OnMount(gps, mounted)
	if mounted then
		self:Interrupt(gps)
	end
end

function Rest:OnTaxi(gps, onTaxi)
	if onTaxi then
		self:Interrupt(gps)
	end
end

function Rest:OnStop(gps)
	self:End(gps)
	self:StopWatch()
	self.sleepArmed = nil
end

ns.GPS:RegisterActivity(Rest)
