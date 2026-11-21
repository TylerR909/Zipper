local _, ns = ...
local L = ns.L

ns.Viz:Register({
	id = "pauses",
	label = L["Pauses"],
	title = L["Pauses"],
	note = L["What're you up to when you're not moving or fighting?"],
	display = "meters",
	displays = { "meters", "pie" },
	Build = function(summary)
		local bag = summary.pauses or {}
		local specs = ns.PauseSpecs or {}
		local rows = {}
		for i = 1, #specs do
			local spec = specs[i]
			local color = spec.color or { 0.62, 0.62, 0.68 }
			rows[#rows + 1] = {
				label = spec.pause.label or spec.name,
				value = bag[spec.pause.key] or 0,
				r = color[1],
				g = color[2],
				b = color[3],
			}
		end
		return { rows = rows }
	end,
})
