local _, ns = ...

local Kind = ns.Kind
-- Recognized after this much stillness; the recorded span backdates to when
-- stillness began. Same window as the parked playhead ring.
local IDLE_RECOGNIZE = 20

local NPC_OPEN = {
	TRAINER_SHOW = true,
	GOSSIP_SHOW = true,
	MERCHANT_SHOW = true,
	MAIL_SHOW = true,
	BANKFRAME_OPENED = true,
	AUCTION_HOUSE_SHOW = true,
	QUEST_GREETING = true,
	QUEST_DETAIL = true,
	QUEST_PROGRESS = true,
	QUEST_COMPLETE = true,
}

local NPC_CLOSE = {
	TRAINER_CLOSED = true,
	GOSSIP_CLOSED = true,
	MERCHANT_CLOSED = true,
	MAIL_CLOSED = true,
	BANKFRAME_CLOSED = true,
	AUCTION_HOUSE_CLOSED = true,
	QUEST_FINISHED = true,
}

local EVENTS = {}
for event in pairs(NPC_OPEN) do
	EVENTS[#EVENTS + 1] = event
end
for event in pairs(NPC_CLOSE) do
	EVENTS[#EVENTS + 1] = event
end

local Idle = {
	id = "idle",
	events = EVENTS,
}

function Idle:Busy(gps)
	return gps.moving
		or gps.onTaxi
		or gps.inCombat
		or self.npcBusy
		or gps:AnyActivityBlocksIdle()
		or false
end

function Idle:Begin(gps, when)
	if not ns.Config:WantsKind(Kind.IDLE) then
		return
	end
	if self.idle or self:Busy(gps) then
		return
	end
	if type(when) ~= "number" then
		when = self.stillSince or ns.DB:Now()
	end
	if not gps:MarkAt(Kind.IDLE, 0, when) then
		return
	end
	self.idle = true
end

function Idle:End(gps)
	if not self.idle then
		return
	end
	self.idle = false
	gps:Mark(Kind.IDLE, 1)
end

function Idle:ClearStill(gps)
	self.stillSince = nil
	if self.idle then
		self:End(gps)
	end
end

function Idle:SetNpcBusy(gps, busy)
	busy = busy and true or false
	if self.npcBusy == busy then
		return
	end
	self.npcBusy = busy
	if busy then
		self:ClearStill(gps)
	else
		self.stillSince = nil
	end
end

function Idle:Watch(gps)
	if not ns.Config:WantsKind(Kind.IDLE) then
		self:ClearStill(gps)
		return
	end
	if self:Busy(gps) then
		self:ClearStill(gps)
		return
	end
	local now = ns.DB:Now()
	if not self.stillSince then
		self.stillSince = now
		return
	end
	if self.idle then
		return
	end
	if now - self.stillSince >= IDLE_RECOGNIZE then
		self:Begin(gps, self.stillSince)
	end
end

function Idle:OnEvent(gps, event)
	if NPC_OPEN[event] then
		self:SetNpcBusy(gps, true)
	elseif NPC_CLOSE[event] then
		self:SetNpcBusy(gps, false)
	end
end

function Idle:OnClearStill(gps)
	self:ClearStill(gps)
end

function Idle:OnMoveStart(gps)
	self:ClearStill(gps)
end

function Idle:OnMoveStop(gps)
	self.stillSince = nil
	self:Watch(gps)
end

function Idle:OnCombat(gps, entered)
	if entered then
		self:ClearStill(gps)
	else
		self.stillSince = nil
	end
end

function Idle:OnTaxi(gps, onTaxi)
	if onTaxi then
		self:ClearStill(gps)
	else
		self.stillSince = nil
	end
end

function Idle:OnTick(gps)
	self:Watch(gps)
end

function Idle:OnStart(gps)
	self.npcBusy = false
	self.stillSince = nil
	if self.idle then
		self:End(gps)
	end
	self:Watch(gps)
end

function Idle:OnStop(gps)
	self:End(gps)
	self.stillSince = nil
	self.npcBusy = false
end

ns.GPS:RegisterActivity(Idle)
