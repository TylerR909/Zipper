local _, ns = ...
local L = ns.L

-- Kills and turn-ins by place. One drawing: grouped bars, each count on its own scale.

local function rows(summary)
	local order = ns.Viz.WhereOrder or {}
	local kills = summary.kills or {}
	local turnins = summary.turnins or {}
	local list = {}
	for i = 1, #order do
		local row = order[i]
		list[#list + 1] = {
			label = L[row.text],
			kills = kills[row.key] or 0,
			turnins = turnins[row.key] or 0,
			r = row.r,
			g = row.g,
			b = row.b,
		}
	end
	if (summary.unplacedKills or 0) > 0 then
		list[#list + 1] = {
			label = L["Unplaced"],
			kills = summary.unplacedKills,
			turnins = 0,
			r = 0.62,
			g = 0.60,
			b = 0.54,
		}
	end
	return list
end

ns.Viz:Register({
	id = "places",
	label = L["Places"],
	title = L["Kills and turn-ins"],
	note = "",
	display = "groups",
	displays = { "groups" },
	Build = function(summary)
		local footer = nil
		if (summary.unplacedKills or 0) > 0 then
			footer = L["Older sessions stored a kill total without a place."]
		end
		return { rows = rows(summary), footer = footer }
	end,
})
