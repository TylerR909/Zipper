local _, ns = ...

local Kind = ns.Kind

local Meal = {
	id = "meal",
	events = {
		"UNIT_AURA",
	},
}

function Meal:Read(gps)
	if gps:AuraIndexSecret(1) then
		return nil
	end
	if not C_UnitAuras or not C_UnitAuras.GetBuffDataByIndex then
		return false
	end
	for i = 1, 40 do
		if gps:AuraIndexSecret(i) then
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

function Meal:OnEvent(gps, event, unit)
	if event == "UNIT_AURA" and unit == "player" and not (issecretvalue and issecretvalue(unit)) then
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
