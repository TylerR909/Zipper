local _, ns = ...
local L = ns.L

local PARTS = {
	{ key = "normal", text = "Normal", r = 0.55, g = 0.52, b = 0.46 },
	{ key = "elite", text = "Elite", r = 1.00, g = 0.25, b = 0.20 },
	{ key = "rare", text = "Rare", r = 1.00, g = 0.82, b = 0.28 },
}

ns.Viz:Register({
	id = "elites",
	label = L["Elite"],
	title = L["Elites and rares"],
	note = L["Rare elites are counted with the elites."],
	display = "stacks",
	displays = { "stacks", "share" },
	Build = function(summary)
		local levels = summary.levels or {}
		if #levels == 0 then
			return { empty = true }
		end
		local footer = nil
		if (summary.unplacedKills or 0) > 0 then
			footer = L["Older sessions stored a kill total without a place."]
		end
		return {
			rows = ns.Viz:LevelRows(summary, { "normal", "elite", "rare" }),
			parts = PARTS,
			footer = footer,
		}
	end,
})
