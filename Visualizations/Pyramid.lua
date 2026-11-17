local _, ns = ...
local L = ns.L

ns.Viz:Register({
	id = "pyramid",
	label = L["Solo and grouped"],
	title = L["Solo and grouped"],
	note = L["Solo kills versus kills in a group."],
	display = "pyramid",
	displays = { "stacks", "share", "pyramid" },
	Build = function(summary)
		return ns.Viz:CompanyModel(summary)
	end,
})
