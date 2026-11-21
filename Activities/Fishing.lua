local _, ns = ...

local Kind = ns.Kind
-- Brief pause between casts stays one fishing span so the map gets one pin.
local FISH_END_GRACE = 2.5

local Fishing = {
	id = "fishing",
	events = {
		"UNIT_SPELLCAST_CHANNEL_START",
		"UNIT_SPELLCAST_CHANNEL_STOP",
	},
}

function Fishing:IsChannel(gps, spellID)
	if ns.FishingSpell(spellID) then
		return true
	end
	local name = gps:SpellName(spellID)
	if ns.FishingSpell(nil, name) then
		return true
	end
	if not UnitChannelInfo then
		return false
	end
	local channelName, _, _, _, _, _, _, channelID = UnitChannelInfo("player")
	if ns.FishingSpell(channelID, channelName) then
		return true
	end
	return false
end

function Fishing:Watch(gps)
	if not ns.Config:WantsKind(Kind.FISH) then
		gps:EndSpan(Kind.FISH)
		return
	end
	if self:IsChannel(gps) then
		gps:BeginSpan(Kind.FISH)
	elseif gps:SpanActive(Kind.FISH) then
		gps:ScheduleEndSpan(Kind.FISH, FISH_END_GRACE)
	end
end

function Fishing:OnEvent(gps, event, unit, _, spellID)
	if (issecretvalue and issecretvalue(unit)) or unit ~= "player" then
		return
	end
	if event == "UNIT_SPELLCAST_CHANNEL_START" then
		if self:IsChannel(gps, spellID) then
			gps:BeginSpan(Kind.FISH)
		end
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if gps:SpanActive(Kind.FISH) or self:IsChannel(gps, spellID) then
			gps:ScheduleEndSpan(Kind.FISH, FISH_END_GRACE)
		end
	end
end

function Fishing:OnStart(gps)
	self:Watch(gps)
end

function Fishing:OnMoveStart(gps)
	gps:EndSpan(Kind.FISH)
end

function Fishing:OnStop(gps)
	gps:EndSpan(Kind.FISH)
end

ns.GPS:RegisterActivity(Fishing)
