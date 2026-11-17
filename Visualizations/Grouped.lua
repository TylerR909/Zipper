local _, ns = ...
local L = ns.L

-- Grouped and solo are both kills, so one model feeds the stack, the share
-- bar, and the pyramid. Share.lua and Pyramid.lua register the other two
-- views and load after this file.
local DISPLAYS = { "stacks", "share", "pyramid" }

local PARTS = {
	{ key = "grouped", text = "Grouped", r = 0.35, g = 0.62, b = 0.95 },
	{ key = "solo", text = "Solo", r = 0.78, g = 0.76, b = 0.70 },
}

function ns.Viz:CompanyModel(summary)
	local levels = summary.levels or {}
	if #levels == 0 then
		return { empty = true }
	end
	local footer = nil
	if (summary.unplacedKills or 0) > 0 then
		footer = L["Older sessions stored a kill total without a place."]
	end
	return {
		rows = self:LevelRows(summary, { "grouped", "solo" }),
		parts = PARTS,
		footer = footer,
	}
end

ns.Viz:Register({
	id = "company",
	label = L["Grouped"],
	title = L["Grouped and solo"],
	note = L["Kills with other players, and solo."],
	display = "stacks",
	displays = DISPLAYS,
	Build = function(summary)
		return ns.Viz:CompanyModel(summary)
	end,
})
