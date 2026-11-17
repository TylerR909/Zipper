local _, ns = ...
local L = ns.L

-- Kills and turn-ins, one group per level.

ns.Viz:Register({
	id = "levels",
	label = L["Levels"],
	title = L["Each level"],
	note = "",
	display = "groups",
	displays = { "groups" },
	Build = function(summary)
		local levels = summary.levels or {}
		if #levels == 0 then
			if (summary.unplacedKills or 0) > 0 then
				return { empty = L["Older sessions stored a kill total without a place."] }
			end
			return { empty = true }
		end
		local rows = ns.Viz:LevelRows(summary, { "kills", "turnins" })
		for i = 1, #rows do
			rows[i].r = 0.78
			rows[i].g = 0.76
			rows[i].b = 0.70
		end
		local footer = nil
		if (summary.unplacedKills or 0) > 0 then
			footer = string.format("%s  %s", ns.Viz:Comma(summary.unplacedKills), L["Older sessions stored a kill total without a place."])
		end
		return { rows = rows, footer = footer }
	end,
})
