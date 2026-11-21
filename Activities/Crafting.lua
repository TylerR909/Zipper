local _, ns = ...

local Kind = ns.Kind
-- Brief pause between Create clicks stays one crafting span for time tracking.
local CRAFT_END_GRACE = 2.5

local Crafting = {
	id = "crafting",
	events = {
		"UNIT_SPELLCAST_START",
		"UNIT_SPELLCAST_STOP",
		"UNIT_SPELLCAST_FAILED",
		"UNIT_SPELLCAST_INTERRUPTED",
		"UNIT_SPELLCAST_SUCCEEDED",
		"UNIT_SPELLCAST_CHANNEL_START",
		"UNIT_SPELLCAST_CHANNEL_STOP",
	},
}

function Crafting:IsCast(gps)
	if UnitCastingInfo then
		local name, _, _, _, _, isTradeskill = UnitCastingInfo("player")
		if type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name ~= "" then
			if gps:PlainBool(isTradeskill) then
				return true
			end
		end
	end
	if UnitChannelInfo then
		local name, _, _, _, _, isTradeskill = UnitChannelInfo("player")
		if type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name ~= "" then
			if gps:PlainBool(isTradeskill) then
				return true
			end
		end
	end
	return false
end

function Crafting:ScheduleEnd(gps)
	gps:ScheduleEndSpan(Kind.CRAFT, CRAFT_END_GRACE, function()
		return self:IsCast(gps)
	end)
end

function Crafting:Watch(gps)
	if not ns.Config:WantsKind(Kind.CRAFT) then
		gps:EndSpan(Kind.CRAFT)
		return
	end
	if self:IsCast(gps) then
		gps:BeginSpan(Kind.CRAFT)
	elseif gps:SpanActive(Kind.CRAFT) then
		self:ScheduleEnd(gps)
	end
end

function Crafting:OnEvent(gps, event, unit, _, spellID)
	if (issecretvalue and issecretvalue(unit)) or unit ~= "player" then
		return
	end
	if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
		self:Watch(gps)
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if gps:PlainNumber(spellID) and gps:SpanActive(Kind.CRAFT) then
			self:ScheduleEnd(gps)
		end
	elseif gps:SpanActive(Kind.CRAFT) then
		self:ScheduleEnd(gps)
	end
end

function Crafting:OnStart(gps)
	self:Watch(gps)
end

function Crafting:OnMoveStart(gps)
	gps:EndSpan(Kind.CRAFT)
end

function Crafting:OnStop(gps)
	gps:EndSpan(Kind.CRAFT)
end

ns.GPS:RegisterActivity(Crafting)
