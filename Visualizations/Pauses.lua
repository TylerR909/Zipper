local _, ns = ...
local L = ns.L

local ORDER = {
	{ key = "idle", text = "Idle", r = 0.62, g = 0.62, b = 0.68 },
	{ key = "afk", text = "AFK", r = 0.55, g = 0.55, b = 0.85 },
	{ key = "camp", text = "Camped", r = 0.95, g = 0.45, b = 0.12 },
	{ key = "sleep", text = "Slept", r = 0.55, g = 0.62, b = 0.95 },
	{ key = "fish", text = "Fishing", r = 0.25, g = 0.55, b = 0.95 },
	{ key = "eat", text = "Eating", r = 0.72, g = 0.58, b = 0.32 },
}

ns.Viz:Register({
	id = "pauses",
	label = L["Pauses"],
	title = L["Pauses"],
	note = L["What're you up to when you're not moving or fighting?"],
	display = "meters",
	displays = { "meters", "pie" },
	Build = function(summary)
		local bag = summary.pauses or {}
		local rows = {}
		for i = 1, #ORDER do
			local row = ORDER[i]
			rows[#rows + 1] = {
				label = L[row.text],
				value = bag[row.key] or 0,
				r = row.r,
				g = row.g,
				b = row.b,
			}
		end
		return { rows = rows }
	end,
})
