local _, ns = ...
local L = ns.L

local ORDER = {
	{ key = "foot", text = "On foot", r = 0.78, g = 0.76, b = 0.70 },
	{ key = "mount", text = "Mounted", r = 1.00, g = 0.55, b = 0.15 },
	{ key = "flight", text = "Flight path", r = 0.20, g = 0.90, b = 0.90 },
	{ key = "ghost", text = "Ghost", r = 0.75, g = 0.75, b = 0.75 },
}

local function rows(bag)
	local list = {}
	for i = 1, #ORDER do
		local row = ORDER[i]
		list[#list + 1] = {
			label = L[row.text],
			value = bag[row.key] or 0,
			r = row.r,
			g = row.g,
			b = row.b,
		}
	end
	return list
end

ns.Viz:Register({
	id = "travel",
	label = L["Moved"],
	title = L["How you moved"],
	note = L["Time spent moving. Standing still is not counted."],
	display = "meters",
	displays = { "meters", "pie" },
	Build = function(summary)
		return { rows = rows(summary.travel or {}), percent = true }
	end,
})
