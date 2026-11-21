local _, ns = ...

local Kind = ns.Kind

local Meal = {
	id = "meal",
	events = {
		"UNIT_AURA",
	},
}

function Meal:Read(gps)
	local camp, _, _, meal = gps:ReadBuffSignals()
	if camp == nil then
		return nil
	end
	return meal
end

function Meal:Watch(gps)
	local eating = self:Read(gps)
	if eating == nil then
		return
	end
	if eating then
		gps:BeginSpan(Kind.EAT)
	else
		gps:EndSpan(Kind.EAT)
	end
end

function Meal:OnEvent(gps, event, unit, updateInfo)
	if event == "UNIT_AURA" and unit == "player" and not (issecretvalue and issecretvalue(unit)) and gps:AuraChanged(updateInfo) then
		self:Watch(gps)
	end
end

function Meal:OnStart(gps)
	self:Watch(gps)
end

function Meal:OnMoveStart(gps)
	gps:EndSpan(Kind.EAT)
end

function Meal:OnStop(gps)
	gps:EndSpan(Kind.EAT)
end

ns.GPS:RegisterActivity(Meal)
