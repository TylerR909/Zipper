local _, ns = ...
local L = ns.L

ns.Viz:Register({
	id = "share",
	label = L["Group share"],
	title = L["Group share"],
	note = L["How much of each level's kills came with a group."],
	display = "share",
	displays = { "stacks", "share", "pyramid" },
	Build = function(summary)
		return ns.Viz:CompanyModel(summary)
	end,
})
