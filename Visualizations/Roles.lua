local _, ns = ...
local L = ns.L

local ORDER = {
	{ key = ns.Role.TANK, text = "Tank", r = 0.30, g = 0.62, b = 0.95 },
	{ key = ns.Role.HEALER, text = "Healer", r = 0.30, g = 0.85, b = 0.45 },
	{ key = ns.Role.DAMAGER, text = "DPS", r = 0.92, g = 0.32, b = 0.28 },
}

ns.Viz:Register({
	id = "roles",
	label = L["Roles"],
	title = L["Roles"],
	note = L["Time spent as Tank, Healer, or DPS."],
	display = "meters",
	displays = { "meters", "pie" },
	Build = function(summary)
		local bag = summary.roles or {}
		local rows = {}
		local total = 0
		for i = 1, #ORDER do
			local spec = ORDER[i]
			local value = bag[spec.key] or 0
			total = total + value
			rows[#rows + 1] = {
				label = L[spec.text],
				value = value,
				r = spec.r,
				g = spec.g,
				b = spec.b,
			}
		end
		if total <= 0 then
			return { empty = L["No role data recorded in this selection yet."] }
		end
		return {
			rows = rows,
			slices = rows,
			percent = true,
			foot = string.format(L["%s total."], ns.Viz:Clock(total)),
		}
	end,
})
