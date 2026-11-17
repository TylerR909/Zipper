local _, ns = ...
local L = ns.L

ns.Viz:Register({
	id = "zones",
	label = L["Zone"],
	title = L["Zones"],
	note = "",
	display = "zones",
	displays = { "zones" },
	Build = function(summary)
		return { zones = summary.zones }
	end,
})
