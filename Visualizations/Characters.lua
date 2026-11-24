local _, ns = ...
local L = ns.L

ns.Viz:Register({
	id = "characters",
	label = L["Characters"],
	title = L["Characters"],
	note = L["Time played per character."],
	display = "meters",
	displays = { "meters", "pie" },
	Build = function(summary)
		local src = summary.characters or {}
		local rows = {}
		for i = 1, #src do
			local item = src[i]
			if (item.seconds or 0) > 0 then
				local r, g, b = ns.Replay:ClassFileColor(item.class)
				rows[#rows + 1] = {
					label = item.label or L["Character"],
					value = item.seconds,
					r = r,
					g = g,
					b = b,
				}
			end
		end
		if #rows == 0 then
			return { empty = true }
		end
		return {
			rows = rows,
			slices = rows,
			percent = true,
			foot = string.format(L["%s total."], ns.Viz:Clock(summary.recorded or 0)),
		}
	end,
})
